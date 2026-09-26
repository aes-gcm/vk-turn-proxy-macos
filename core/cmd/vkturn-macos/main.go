// Command vkturn-macos is a native macOS CLI harness for the VK-TURN-proxy
// core. It mirrors the iOS PacketTunnel wiring (WireGuardBridge/bridge.go)
// but, instead of receiving a TUN fd from a NetworkExtension, it creates a
// real utun via wireguard-go's darwin path — so it needs root.
//
// Pipeline (identical to iOS): SetVKCookieAuth -> NewProxy(cfg) -> Start ->
// WaitBootstrap -> NewTURNBind -> CreateTUN("utun") -> device.NewDevice ->
// IpcSet(UAPI) -> Up. This is Stage 1 of the macOS port: it proves the core
// links and boots on darwin. Interface/route/DNS configuration (root) is
// best-effort and gated behind -up.
package main

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/cacggghp/vk-turn-proxy/pkg/proxy"
	"github.com/cacggghp/vk-turn-proxy/pkg/turnbind"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

// pidPath is where a root-run instance records its pid so `-stop` can find it.
const pidPath = "/Library/Application Support/VKTurnProxy/helper.pid"

// fileConfig is the JSON the GUI writes (mode 0600) and passes via -config, so
// the VK cookie + WG keys never appear on the command line / in `ps`.
type fileConfig struct {
	VKLink    string `json:"vk_link"`
	VKCookie  string `json:"vk_cookie"`
	Peer      string `json:"peer"`
	N         int    `json:"n"`
	Mode      string `json:"mode"`
	WGPrivate string `json:"wg_private"`
	WGPeerPub string `json:"wg_peer_pub"`
	WGPSK     string `json:"wg_psk"`
	WGAddress string `json:"wg_address"`
	WGDNS     string `json:"wg_dns"`
	Allowed   string `json:"allowed"`
	Keepalive *int   `json:"keepalive"`
	MTU       *int   `json:"mtu"`
	Up        *bool  `json:"up"`
}

// b64ToHex converts a standard/url-safe base64 WireGuard key to the lowercase
// hex the wireguard-go UAPI expects. Mirrors TunnelManager.parseWireGuardKey.
func b64ToHex(in, field string) (string, error) {
	c := strings.TrimSpace(in)
	if c == "" {
		return "", fmt.Errorf("%s is empty", field)
	}
	c = strings.NewReplacer("-", "+", "_", "/").Replace(c)
	raw, err := base64.StdEncoding.DecodeString(c)
	if err != nil {
		// tolerate missing padding
		if raw, err = base64.RawStdEncoding.DecodeString(strings.TrimRight(c, "=")); err != nil {
			return "", fmt.Errorf("%s: invalid base64: %w", field, err)
		}
	}
	if len(raw) != 32 {
		return "", fmt.Errorf("%s: want 32 bytes, got %d", field, len(raw))
	}
	return hex.EncodeToString(raw), nil
}

func run(cmd string, args ...string) error {
	c := exec.Command(cmd, args...)
	c.Stdout, c.Stderr = os.Stdout, os.Stderr
	log.Printf("+ %s %s", cmd, strings.Join(args, " "))
	return c.Run()
}

func main() {
	var (
		vkLink   = flag.String("vk-link", "", "VK call invite link or id (https://vk.ru/call/join/...)")
		cookie   = flag.String("vk-cookie", "", "raw VK Cookie header: \"remixsid=...; p=...\" (enables captcha-free path)")
		peer     = flag.String("peer", "", "vk-turn-proxy server address host:port (REQUIRED)")
		nConns   = flag.Int("n", 30, "concurrent TURN connections")
		mode     = flag.String("mode", "srtp", "transport: srtp | dtls | udp | tcp")
		wgPriv   = flag.String("wg-private", "", "WireGuard client private key (base64)")
		wgPub    = flag.String("wg-peer-pub", "", "WireGuard server public key (base64)")
		wgPSK    = flag.String("wg-psk", "", "WireGuard preshared key (base64, optional)")
		wgAddr   = flag.String("wg-address", "10.66.66.5/24", "tunnel interface address CIDR")
		wgDNS    = flag.String("wg-dns", "1.1.1.1", "DNS server to set while up")
		allowed  = flag.String("allowed", "0.0.0.0/0", "WireGuard allowed_ip")
		keepal   = flag.Int("keepalive", 25, "persistent keepalive seconds (0=off)")
		mtu      = flag.Int("mtu", 1280, "tunnel MTU")
		bootWait = flag.Int("bootstrap-timeout", 60, "seconds to wait for VK bootstrap")
		bringUp  = flag.Bool("up", false, "configure interface + routes + DNS (needs root)")
		cfgFile  = flag.String("config", "", "path to JSON config file (overrides flags; keeps secrets off argv)")
		stop     = flag.Bool("stop", false, "stop a running instance (reads pidfile), restore DNS, exit")
		check    = flag.Bool("check", false, "print ok and exit 0 (probe: helper installed + passwordless sudo works)")
		flush    = flag.Bool("flush", false, "remove stale VK/OK exclusion routes and exit")
	)
	flag.Parse()

	if *check {
		fmt.Println("ok")
		return
	}
	if *flush {
		flushVKRoutes()
		return
	}

	// -stop: signal a running helper (used by the GUI's disconnect, via sudo -n
	// so it needs no password once the helper is installed).
	if *stop {
		if data, err := os.ReadFile(pidPath); err == nil {
			if p, perr := strconv.Atoi(strings.TrimSpace(string(data))); perr == nil {
				_ = syscall.Kill(p, syscall.SIGTERM)
				log.Printf("sent SIGTERM to %d", p)
			}
			_ = os.Remove(pidPath)
		}
		restoreNetwork()
		return
	}

	// A -config file overrides the flags — this is how the GUI invokes us.
	if *cfgFile != "" {
		raw, err := os.ReadFile(*cfgFile)
		if err != nil {
			log.Fatalf("read -config: %v", err)
		}
		var fc fileConfig
		if err := json.Unmarshal(raw, &fc); err != nil {
			log.Fatalf("parse -config: %v", err)
		}
		if fc.VKLink != "" {
			*vkLink = fc.VKLink
		}
		if fc.VKCookie != "" {
			*cookie = fc.VKCookie
		}
		if fc.Peer != "" {
			*peer = fc.Peer
		}
		if fc.N != 0 {
			*nConns = fc.N
		}
		if fc.Mode != "" {
			*mode = fc.Mode
		}
		if fc.WGPrivate != "" {
			*wgPriv = fc.WGPrivate
		}
		if fc.WGPeerPub != "" {
			*wgPub = fc.WGPeerPub
		}
		if fc.WGPSK != "" {
			*wgPSK = fc.WGPSK
		}
		if fc.WGAddress != "" {
			*wgAddr = fc.WGAddress
		}
		if fc.WGDNS != "" {
			*wgDNS = fc.WGDNS
		}
		if fc.Allowed != "" {
			*allowed = fc.Allowed
		}
		if fc.Keepalive != nil {
			*keepal = *fc.Keepalive
		}
		if fc.MTU != nil {
			*mtu = *fc.MTU
		}
		if fc.Up != nil {
			*bringUp = *fc.Up
		}
	}

	if *peer == "" || *vkLink == "" {
		log.Fatal("both -peer and -vk-link are required (via flags or -config)")
	}
	if !*bringUp && os.Geteuid() != 0 {
		log.Printf("note: running without -up (bootstrap-only test); -up requires sudo")
	}

	// record pid so `-stop` can signal us (best-effort; needs the root dir)
	if *bringUp {
		_ = os.MkdirAll("/Library/Application Support/VKTurnProxy", 0o755)
		_ = os.WriteFile(pidPath, []byte(strconv.Itoa(os.Getpid())), 0o644)
		defer os.Remove(pidPath)
		// Clear stale VK exclusion routes (old gateway after a network change)
		// so bootstrap reaches VK over the current default route.
		flushVKRoutes()
	}

	// VK call links: one per line/space. In cookie mode each link is a distinct
	// relay-cluster the cred pool can use, so MORE links => more parallel TURN
	// => more speed (this is how the iOS app scales throughput).
	links := splitLinks(*vkLink)
	if len(links) == 0 {
		links = []string{*vkLink}
	}

	// --- transport mode ---
	cfg := proxy.Config{
		PeerAddr: *peer,
		VKLink:   links[0],
		NumConns: *nConns,
	}
	switch strings.ToLower(*mode) {
	case "srtp":
		cfg.UseSrtp = true
	case "dtls":
		cfg.UseDTLS = true
	case "udp":
		cfg.UseDTLS = true
		cfg.UseUDP = true
	case "tcp":
		cfg.UseDTLS = true
	default:
		log.Fatalf("unknown -mode %q", *mode)
	}

	// --- captcha-free cookie path ---
	if *cookie != "" {
		proxy.SetVKCookieAuth(true, *cookie, links)
		// Cred pool is ~2×links; conns beyond links×20 churn forever on a
		// saturated pool (matches the iOS effectiveNumConnections cap). Cap so
		// we run clean instead of thrashing — the real cause of "slow on mac".
		cap := min(50, max(2, len(links)*20))
		if cfg.NumConns > cap {
			log.Printf("cookie mode: capping connections %d → %d (%d call link(s) × 20)", cfg.NumConns, cap, len(links))
			cfg.NumConns = cap
		}
		log.Printf("cookie auth ENABLED (captcha-free path), %d link(s), %d conns", len(links), cfg.NumConns)
	} else {
		log.Printf("cookie auth OFF — anonymous path (captcha-prone). Pass -vk-cookie for the iOS-grade path.")
	}

	// --- start proxy + wait for first live TURN/DTLS conn ---
	p := proxy.NewProxy(cfg)
	go func() {
		if err := p.Start(); err != nil {
			log.Printf("proxy.Start: %v", err)
		}
	}()
	log.Printf("bootstrapping VK/TURN (mode=%s, n=%d)…", *mode, *nConns)
	if err := p.WaitBootstrap(time.Duration(*bootWait) * time.Second); err != nil {
		log.Fatalf("bootstrap failed: %v", err)
	}
	log.Printf("bootstrap READY. TURN server ip=%s", p.TURNServerIP())

	// --- WireGuard device over the TURN bind ---
	tdev, err := tun.CreateTUN("utun", *mtu)
	if err != nil {
		log.Fatalf("CreateTUN: %v (utun creation needs root)", err)
	}
	ifname, _ := tdev.Name()
	log.Printf("created tunnel interface %s (mtu %d)", ifname, *mtu)

	bind := turnbind.NewTURNBind(p)
	logger := device.NewLogger(device.LogLevelVerbose, "(wg-turn) ")
	dev := device.NewDevice(tdev, bind, logger)

	uapi, err := buildUAPI(*wgPriv, *wgPub, *wgPSK, *peer, *allowed, *keepal)
	if err != nil {
		log.Fatalf("build UAPI: %v", err)
	}
	if err := dev.IpcSet(uapi); err != nil {
		log.Fatalf("IpcSet: %v", err)
	}
	if err := dev.Up(); err != nil {
		log.Fatalf("device.Up: %v", err)
	}
	log.Printf("WireGuard device up on %s", ifname)

	if *bringUp {
		if err := configureInterface(ifname, *wgAddr, *wgDNS, p.TURNServerIP()); err != nil {
			// Never leave a half-configured tunnel that black-holes the net.
			log.Printf("interface config FAILED: %v — tearing down", err)
			restoreNetwork()
			p.StopWithTimeout(2 * time.Second)
			dev.Close()
			os.Remove(pidPath)
			log.Fatalf("aborted: %v", err)
		}
	} else {
		log.Printf("skipping interface config (no -up). To route traffic: sudo %s -up …", os.Args[0])
	}

	// --- wait for signal, then tear down (proxy first, then device) ---
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	log.Printf("running. Ctrl-C to stop.")
	<-sig
	log.Printf("shutting down…")
	// Order: proxy first, then device (avoids the WG<->proxy close deadlock).
	p.StopWithTimeout(2 * time.Second)
	dev.Close()
	if *bringUp {
		// Explicitly undo routes + DNS (don't rely on the utun teardown) so the
		// internet returns immediately — never needs a reboot.
		restoreNetwork()
	}
	log.Printf("stopped.")
}

func buildUAPI(priv, pub, psk, endpoint, allowed string, keepalive int) (string, error) {
	privHex, err := b64ToHex(priv, "private key")
	if err != nil {
		return "", err
	}
	pubHex, err := b64ToHex(pub, "peer public key")
	if err != nil {
		return "", err
	}
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\n", privHex)
	b.WriteString("replace_peers=true\n")
	fmt.Fprintf(&b, "public_key=%s\n", pubHex)
	fmt.Fprintf(&b, "endpoint=%s\n", endpoint) // ignored by TURNBind, must parse
	if keepalive > 0 {
		fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", keepalive)
	}
	for _, ip := range strings.Split(allowed, ",") {
		if t := strings.TrimSpace(ip); t != "" {
			fmt.Fprintf(&b, "allowed_ip=%s\n", t)
		}
	}
	if strings.TrimSpace(psk) != "" {
		pskHex, err := b64ToHex(psk, "preshared key")
		if err != nil {
			return "", err
		}
		fmt.Fprintf(&b, "preshared_key=%s\n", pskHex)
	}
	return b.String(), nil
}

// configureInterface assigns the tunnel IP, points the default route at the
// utun (wg-quick's 0/1+128/1 split), keeps the TURN relay reachable via the
// physical gateway, and sets DNS. Best-effort; needs root. The VK-range
// exclusion (so the proxy's own VK traffic escapes the tunnel) is the
// privileged-helper's job in the GUI build — here we only pin the live TURN ip.
// Absolute paths — under `sudo` PATH may not include /sbin, which silently
// broke `route`/`ifconfig` lookups (the real reason stale-route flushing failed).
const (
	routeBin   = "/sbin/route"
	ifconfigB  = "/sbin/ifconfig"
	netsetupB  = "/usr/sbin/networksetup"
	netstatBin = "/usr/sbin/netstat"
)

func configureInterface(ifname, cidr, dns, turnIP string) error {
	ip := cidr
	if i := strings.IndexByte(cidr, '/'); i >= 0 {
		ip = cidr[:i]
	}
	if other := defaultViaUTUN(); other != "" && other != ifname {
		log.Printf("another VPN is active (default via %s) — disable it first, routing will conflict", other)
	}
	_ = run(ifconfigB, ifname, "inet", ip, ip, "up")
	gw := physicalGateway()
	if gw == "" {
		// CRITICAL: without a physical gateway we cannot exclude VK traffic, so
		// installing the default-via-tunnel here would black-hole ALL internet.
		// Refuse and let the caller tear the tunnel down.
		return fmt.Errorf("no physical gateway (another VPN active, or offline) — refusing to route to avoid killing connectivity")
	}
	// The proxy's OWN traffic to VK/OK (auth + TURN media relays) MUST bypass
	// the tunnel or it loops into the WG device (that IS the tunnel's uplink).
	for _, n := range vkExcludeCIDRs() {
		_ = run(routeBin, "-n", "delete", "-net", n)
		_ = run(routeBin, "-n", "add", "-net", n, gw)
	}
	// default via tunnel (0/1+128/1 split so the saved default survives)
	_ = run(routeBin, "-n", "add", "-net", "0.0.0.0/1", "-interface", ifname)
	_ = run(routeBin, "-n", "add", "-net", "128.0.0.0/1", "-interface", ifname)
	if dns != "" {
		_ = run(netsetupB, "-setdnsservers", "Wi-Fi", dns)
	}
	log.Printf("interface configured (gw=%s, VK ranges excluded).", gw)
	return nil
}

// restoreNetwork undoes everything configureInterface did — remove the
// default-via-tunnel split, drop VK exclusion routes, and restore DHCP DNS.
// Idempotent and safe to call when nothing was set. This is what guarantees
// the internet comes back on stop/crash without a reboot.
func restoreNetwork() {
	_ = exec.Command(routeBin, "-n", "delete", "-net", "0.0.0.0/1").Run()
	_ = exec.Command(routeBin, "-n", "delete", "-net", "128.0.0.0/1").Run()
	flushVKRoutes()
	_ = exec.Command(netsetupB, "-setdnsservers", "Wi-Fi", "Empty").Run()
}

// vkOctets — first-two-octet prefixes of VK/OK infrastructure AND the OK.ru
// media TURN relays (90.156.x, 95.163.x, …) VK hands out. Broad /16 coverage so
// whichever relay we get bypasses the tunnel and stale routes are recognisable.
var vkOctets = []string{
	"87.240", "93.186", "95.142", "95.163", "95.213", "90.156",
	"79.137", "91.231", "185.32", "185.131", "128.140", "217.69", "155.212",
}

func vkExcludeCIDRs() []string {
	out := make([]string, 0, len(vkOctets))
	for _, o := range vkOctets {
		out = append(out, o+".0.0/16")
	}
	return out
}

// destInVK reports whether a routing-table destination (possibly abbreviated,
// e.g. "95.213/18", or a bare host "95.163.34.177") sits in a VK/OK supernet.
func destInVK(dest string) bool {
	d := dest
	if i := strings.IndexByte(d, '/'); i >= 0 {
		d = d[:i]
	}
	octs := strings.Split(d, ".")
	if len(octs) < 2 {
		return false
	}
	pfx := octs[0] + "." + octs[1]
	for _, o := range vkOctets {
		if o == pfx {
			return true
		}
	}
	return false
}

// expandDest turns netstat's abbreviated destination ("95.213/18") into a form
// route(8) accepts ("95.213.0.0/18"); a bare host passes through unchanged.
func expandDest(dest string) string {
	host, suffix := dest, ""
	if i := strings.IndexByte(dest, '/'); i >= 0 {
		host, suffix = dest[:i], dest[i:]
	}
	octs := strings.Split(host, ".")
	for len(octs) < 4 {
		octs = append(octs, "0")
	}
	return strings.Join(octs, ".") + suffix
}

// flushVKRoutes deletes EVERY VK/OK route in the table that has an explicit
// IPv4 gateway — leftovers from a previous network/gateway that now black-hole
// VK. Reads each route's real destination/prefix, so it works across network
// changes and mixed prefix lengths (/18, /21, /32) that a fixed list can't
// match. A normal system has no such per-VK routes, so this only removes ours.
func flushVKRoutes() {
	out, err := exec.Command(netstatBin, "-rn", "-f", "inet").Output()
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		dest, gw := f[0], f[1]
		if !strings.Contains(gw, ".") { // only routes via an IPv4 gateway
			continue
		}
		if !destInVK(dest) {
			continue
		}
		_ = exec.Command(routeBin, "-n", "delete", expandDest(dest)).Run()
		log.Printf("flushed VK route %s (was via %s)", dest, gw)
	}
}

// splitLinks parses a multiline/space-separated set of VK call links.
func splitLinks(s string) []string {
	var out []string
	for _, f := range strings.Fields(s) {
		f = strings.TrimSpace(f)
		if f != "" {
			out = append(out, f)
		}
	}
	return out
}

// defaultViaUTUN reports the utun interface that currently owns the default
// route, or "" if the physical link does. Used to warn about a conflicting VPN.
func defaultViaUTUN() string {
	out, err := exec.Command("sh", "-c",
		`/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2}'`).Output()
	if err != nil {
		return ""
	}
	iface := strings.TrimSpace(string(out))
	if strings.HasPrefix(iface, "utun") {
		return iface
	}
	return ""
}

func physicalGateway() string {
	out, err := exec.Command("sh", "-c",
		`/usr/sbin/netstat -rn -f inet | awk '$1=="default" && $NF !~ /utun/ {print $2; exit}'`).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}
