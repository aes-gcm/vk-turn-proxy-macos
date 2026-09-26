import Foundation

/// Command construction kept separate so quoting can be tested without root.
enum InstallerCommands {
    static let helperPath = "/Library/PrivilegedHelperTools/com.vkturn.macos.helper"

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func appleScript(_ shell: String) -> String {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    static func installScript(bundled: String, userID: UInt32) -> String {
        let rule = "#\(userID) ALL=(root) NOPASSWD: \(helperPath)"
        return """
        set -eu
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        /usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        helper_tmp=$(/usr/bin/mktemp /Library/PrivilegedHelperTools/.vkturn.XXXXXX)
        rule_tmp=''
        trap '/bin/rm -f "$helper_tmp" "$rule_tmp"' EXIT
        rule_tmp=$(/usr/bin/mktemp /etc/sudoers.d/.vkturn.XXXXXX)
        /usr/bin/install -o root -g wheel -m 755 \(shellQuote(bundled)) "$helper_tmp"
        /usr/bin/codesign --verify --strict "$helper_tmp"
        /usr/bin/printf '%s\\n' \(shellQuote(rule)) > "$rule_tmp"
        /usr/sbin/chown root:wheel "$rule_tmp"
        /bin/chmod 440 "$rule_tmp"
        /usr/sbin/visudo -cf "$rule_tmp"
        /bin/mv -f "$helper_tmp" \(shellQuote(helperPath))
        /bin/mv -f "$rule_tmp" /etc/sudoers.d/vkturn
        """
    }
}
