import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Panel {
    id: root

    property string connectionState: "Checking connection…"
    property string lastError: ""
    property bool otpRequired: false
    property bool savingSecret: false
    property bool credentialKnown: false
    property bool loadingSettings: false
    property var vpn: ({
        "connected": false,
        "clientIp": "",
        "interface": "",
        "sentBytes": 0,
        "receivedBytes": 0,
        "durationSec": 0
    })
    property var serverHistory: []
    property var profiles: []
    readonly property string agentPath: String(Qt.resolvedUrl("scripts/netextender-agent")).replace("file://", "")
    readonly property color dim: Qt.darker(barForeground, 1.55)
    readonly property bool connecting: connectProcess.running || savingSecret
    readonly property bool connected: vpn && vpn.connected === true

    function clean(value) {
        return String(value || "").trim();
    }

    function humanBytes(value) {
        var bytes = Number(value || 0);
        if (bytes < 1024)
            return Math.round(bytes) + " B";

        var units = ["KB", "MB", "GB", "TB"];
        var index = -1;
        do {
            bytes /= 1024;
            index++;
        } while (bytes >= 1024 && index < units.length - 1)
        return bytes.toFixed(bytes >= 100 ? 0 : 1) + " " + units[index];
    }

    function humanDuration(value) {
        var seconds = Math.max(0, Math.floor(Number(value || 0)));
        var hours = Math.floor(seconds / 3600);
        var minutes = Math.floor((seconds % 3600) / 60);
        var rest = seconds % 60;
        return (hours > 0 ? hours + "h " : "") + (hours > 0 || minutes > 0 ? minutes + "m " : "") + rest + "s";
    }

    function updateSettings() {
        if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function")
            return ;

        var entry = {
            "id": moduleName
        };
        for (var key in settings) if (key !== "id") {
            entry[key] = settings[key];
        }
        entry.server = clean(serverField.text);
        entry.username = clean(usernameField.text);
        entry.domain = clean(domainField.text);
        entry.serverHistory = serverHistory;
        entry.profiles = profiles;
        bar.shell.updateEntryInline(moduleName, entry);
    }

    function profileLabel(profile) {
        if (!profile)
            return "";

        return clean(profile.server) + "  ·  " + clean(profile.username) + "  ·  " + clean(profile.domain);
    }

    function rememberProfile() {
        var nextProfile = {
            "server": clean(serverField.text),
            "username": clean(usernameField.text),
            "domain": clean(domainField.text)
        };
        if (!nextProfile.server || !nextProfile.username || !nextProfile.domain)
            return ;

        var next = [nextProfile];
        for (var i = 0; i < profiles.length && next.length < 12; i++) {
            var current = profiles[i] || {
            };
            if (clean(current.server) !== nextProfile.server || clean(current.username) !== nextProfile.username || clean(current.domain) !== nextProfile.domain)
                next.push({
                "server": clean(current.server),
                "username": clean(current.username),
                "domain": clean(current.domain)
            });

        }
        profiles = next;
    }

    function loadSavedSettings() {
        if (serverField.activeFocus || usernameField.activeFocus || domainField.activeFocus)
            return ;

        loadingSettings = true;
        serverField.text = String(setting("server", ""));
        usernameField.text = String(setting("username", ""));
        domainField.text = String(setting("domain", ""));
        serverHistory = setting("serverHistory", []) instanceof Array ? setting("serverHistory", []) : [];
        profiles = setting("profiles", []) instanceof Array ? setting("profiles", []) : [];
        // Migrate settings written by earlier versions into the profile list.
        var migrated = profiles.length === 0 && clean(serverField.text) && clean(usernameField.text) && clean(domainField.text);
        if (migrated)
            rememberProfile();

        loadingSettings = false;
        checkStoredCredential();
        if (migrated)
            Qt.callLater(updateSettings);

    }

    function rememberServer(server) {
        var value = clean(server);
        if (value === "")
            return ;

        var next = [value];
        for (var i = 0; i < serverHistory.length && next.length < 8; i++) {
            var old = clean(serverHistory[i]);
            if (old !== "" && old !== value && next.indexOf(old) === -1)
                next.push(old);

        }
        serverHistory = next;
    }

    function configArgs(action) {
        return [agentPath, action, "--server", clean(serverField.text), "--username", clean(usernameField.text), "--domain", clean(domainField.text)];
    }

    function validConfiguration() {
        if (clean(serverField.text) === "" || clean(usernameField.text) === "" || clean(domainField.text) === "") {
            lastError = "Server, username, and domain are required.";
            return false;
        }
        return true;
    }

    function checkStoredCredential() {
        if (credentialProcess.running)
            return ;

        if (clean(serverField.text) === "" || clean(usernameField.text) === "" || clean(domainField.text) === "") {
            credentialKnown = false;
            return ;
        }
        credentialProcess.command = configArgs("has-secret");
        credentialProcess.running = true;
    }

    function setCredentialKnown(available) {
        credentialKnown = available;
        if (available && !passwordField.activeFocus && clean(passwordField.text) === "") {
            passwordField.storedSecretPreview = true;
            passwordField.text = passwordField.storedSecretMask;
        } else if (!available && passwordField.storedSecretPreview) {
            passwordField.storedSecretPreview = false;
            passwordField.text = "";
        }
    }

    function startConnection() {
        if (connecting || connected || !validConfiguration())
            return ;

        lastError = "";
        rememberServer(serverField.text);
        rememberProfile();
        updateSettings();
        if (clean(passwordField.text) !== "" && !passwordField.storedSecretPreview) {
            savingSecret = true;
            secretProcess.secret = passwordField.text;
            passwordField.text = "";
            secretProcess.command = configArgs("store-secret");
            secretProcess.running = true;
            return ;
        }
        launchConnection();
    }

    function launchConnection() {
        if (connectProcess.running)
            return ;

        connectionState = "Connecting securely…";
        connectProcess.command = configArgs("connect");
        connectProcess.running = true;
    }

    function handleAgentEvent(line) {
        var eventData;
        try {
            eventData = JSON.parse(String(line || ""));
        } catch (_) {
            return ;
        }
        console.debug("NetExtender agent event: " + String(eventData.event || "unknown"));
        if (eventData.event === "connecting") {
            connectionState = "Connecting securely…";
        } else if (eventData.event === "needs_otp") {
            connectionState = "Verification code required";
            otpRequired = true;
        } else if (eventData.event === "verifying_otp") {
            otpRequired = false;
            connectionState = "Verifying code…";
        } else if (eventData.event === "disconnecting") {
            connectionState = "Disconnecting…";
        } else if (eventData.event === "stored") {
            setCredentialKnown(true);
        } else if (eventData.event === "credential") {
            setCredentialKnown(eventData.available === true);
        } else if (eventData.event === "error") {
            otpRequired = false;
            lastError = String(eventData.message || "Connection failed.");
            connectionState = "Connection failed";
        } else if (eventData.event === "ended" && !connected && lastError === "") {
            connectionState = "Disconnected";
        }
    }

    function disconnect() {
        otpRequired = false;
        if (connectProcess.running)
            connectProcess.signal(15);

        if (!actionProcess.running) {
            connectionState = "Disconnecting…";
            actionProcess.command = [agentPath, "disconnect"];
            actionProcess.running = true;
        }
    }

    function refresh() {
        if (!statusProcess.running) {
            statusProcess.command = [agentPath, "status"];
            statusProcess.running = true;
        }
    }

    function submitOtp() {
        var code = clean(otpField.text);
        if (code === "" || !connectProcess.running)
            return ;

        connectProcess.write(code + "\n");
        otpField.text = "";
        otpRequired = false;
        connectionState = "Verifying code…";
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight
    moduleName: "danluan.netextender"
    ipcTarget: "danluan.netextender"
    manageIpc: false
    Component.onCompleted: {
        loadSavedSettings();
        refresh();
    }
    onSettingsChanged: Qt.callLater(loadSavedSettings)

    IpcHandler {
        function open() {
            root.open();
        }

        function close() {
            root.close();
        }

        function toggle() {
            root.toggle();
        }

        function refresh() {
            root.refresh();
        }

        function disconnect() {
            root.disconnect();
        }

        target: root.ipcTarget
    }

    Process {
        id: statusProcess

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    root.vpn = JSON.parse(String(text || "{}"));
                    root.connectionState = root.vpn.connected ? "Connected" : (root.connecting ? root.connectionState : "Disconnected");
                } catch (_) {
                    root.lastError = "Could not read VPN status.";
                }
            }
        }

    }

    Process {
        id: actionProcess

        onExited: {
            refreshTimer.restart();
            root.refresh();
        }

        stdout: SplitParser {
            onRead: function(line) {
                root.handleAgentEvent(line);
            }
        }

    }

    Process {
        id: secretProcess

        property string secret: ""

        stdinEnabled: true
        onStarted: {
            write(secret + "\n");
            secret = "";
        }
        onExited: function(exitCode) {
            savingSecret = false;
            if (exitCode === 0)
                launchConnection();
            else if (lastError === "")
                lastError = "Could not save the password in the system keyring.";
        }

        stdout: SplitParser {
            onRead: function(line) {
                root.handleAgentEvent(line);
            }
        }

    }

    Process {
        id: credentialProcess

        stdout: SplitParser {
            onRead: function(line) {
                root.handleAgentEvent(line);
            }
        }

    }

    Process {
        id: connectProcess

        stdinEnabled: true
        onExited: function(exitCode) {
            otpRequired = false;
            if (exitCode !== 0 && lastError === "")
                lastError = "NetExtender stopped before connecting.";

            refreshTimer.restart();
            refresh();
        }

        stdout: SplitParser {
            onRead: function(line) {
                root.handleAgentEvent(line);
            }
        }

    }

    Timer {
        id: refreshTimer

        interval: 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    BarIconButton {
        id: button

        anchors.fill: parent
        bar: root.bar
        onPressed: function(buttonCode) {
            if (buttonCode === Qt.RightButton)
                root.disconnect();
            else if (buttonCode === Qt.MiddleButton)
                root.refresh();
            else
                root.toggle();
        }

        iconComponent: Component {
            Item {
                Text {
                    anchors.centerIn: parent
                    text: root.connected ? "󰦝" : "󱦚"
                    color: root.connected ? root.barForeground : root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.icon
                }

                Rectangle {
                    visible: root.connecting
                    width: Style.space(5)
                    height: width
                    radius: width / 2
                    color: Color.accent
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                }

            }

        }

    }

    KeyboardPanel {
        id: panel

        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        contentWidth: panel.fittedContentWidth(Style.space(470))
        contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(560))

        ColumnLayout {
            id: content

            width: parent.width
            spacing: Style.space(14)

            RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(10)

                Text {
                    text: root.connected ? "󰦝" : "󱦚"
                    color: root.connected ? Color.accent : root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.space(24)
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(1)

                    Text {
                        text: "NETEXTENDER"
                        color: root.barForeground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                        font.letterSpacing: 1.2
                    }

                    Text {
                        text: root.connectionState
                        color: root.connected ? Color.accent : root.dim
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                    }

                }

                Button {
                    iconText: "󰑐"
                    tooltipText: "Refresh status"
                    foreground: root.barForeground
                    onClicked: root.refresh()
                }

            }

            PanelSeparator {
                Layout.fillWidth: true
                foreground: root.barForeground
            }

            ColumnLayout {
                visible: !root.connected
                Layout.fillWidth: true
                spacing: Style.space(10)

                FormRow {
                    label: "Server"

                    TextField {
                        id: serverField

                        Layout.fillWidth: true
                        foreground: root.barForeground
                        placeholderText: "vpn.example.com:443"
                        onEditingFinished: {
                            root.rememberServer(text);
                            root.updateSettings();
                            root.checkStoredCredential();
                        }
                    }

                    Button {
                        iconText: "󰅀"
                        tooltipText: "Recent servers"
                        foreground: root.barForeground
                        bordered: true
                        onClicked: serverMenu.open()

                        Popup {
                            id: serverMenu

                            x: parent.width - width
                            y: parent.height + Style.space(4)
                            width: Style.space(320)
                            padding: Style.space(6)
                            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                            background: BorderSurface {
                                color: Color.popups.background
                                borderSpec: Border.controlSpec("normal", root.barForeground, Color.accent)
                                radius: Style.cornerRadius
                            }

                            contentItem: Column {
                                width: parent.width

                                Repeater {
                                    model: root.profiles.length > 0 ? root.profiles : root.serverHistory

                                    Button {
                                        required property var modelData

                                        width: parent.width
                                        text: root.profiles.length > 0 ? root.profileLabel(modelData) : String(modelData)
                                        leftAlign: true
                                        foreground: root.barForeground
                                        onClicked: {
                                            if (root.profiles.length > 0) {
                                                serverField.text = String(modelData.server || "");
                                                usernameField.text = String(modelData.username || "");
                                                domainField.text = String(modelData.domain || "");
                                                root.checkStoredCredential();
                                            } else {
                                                serverField.text = String(modelData);
                                            }
                                            serverMenu.close();
                                        }
                                    }

                                }

                                Text {
                                    visible: root.serverHistory.length === 0
                                    width: parent.width
                                    text: "No recent servers"
                                    color: root.dim
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.bodySmall
                                    horizontalAlignment: Text.AlignHCenter
                                }

                            }

                        }

                    }

                }

                FormRow {
                    label: "Username"

                    TextField {
                        id: usernameField

                        Layout.fillWidth: true
                        foreground: root.barForeground
                        placeholderText: "username"
                        onEditingFinished: {
                            root.updateSettings();
                            root.checkStoredCredential();
                        }
                    }

                }

                FormRow {
                    label: "Password"

                    TextField {
                        id: passwordField

                        property bool storedSecretPreview: false
                        readonly property string storedSecretMask: "********"

                        Layout.fillWidth: true
                        foreground: root.barForeground
                        password: true
                        passwordCharacter: "*"
                        placeholderText: "Stored securely in system keyring"
                        onActiveFocusChanged: {
                            if (activeFocus && storedSecretPreview) {
                                storedSecretPreview = false;
                                text = "";
                            } else if (!activeFocus && root.credentialKnown && clean(text) === "") {
                                storedSecretPreview = true;
                                text = storedSecretMask;
                            }
                        }
                    }

                }

                Text {
                    visible: root.credentialKnown
                    Layout.fillWidth: true
                    Layout.leftMargin: Style.space(88)
                    text: "󰌾  Password saved securely in the system keyring"
                    color: Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                }

                FormRow {
                    label: "Domain"

                    TextField {
                        id: domainField

                        Layout.fillWidth: true
                        foreground: root.barForeground
                        placeholderText: "domain"
                        onEditingFinished: {
                            root.updateSettings();
                            root.checkStoredCredential();
                        }
                    }

                }

                Text {
                    visible: root.lastError !== ""
                    Layout.fillWidth: true
                    text: root.lastError
                    color: root.bar ? root.bar.urgent : "#e06c75"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.Wrap
                }

                Item {
                    Layout.fillHeight: true
                    Layout.minimumHeight: Style.space(4)
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(4)
                    spacing: Style.space(8)

                    Item {
                        Layout.fillWidth: true
                    }

                    Button {
                        text: "Disconnect"
                        iconText: "󰅖"
                        foreground: root.barForeground
                        bordered: true
                        enabled: root.connecting || root.connected
                        onClicked: root.disconnect()
                    }

                    Button {
                        text: root.connecting ? "Connecting…" : "Connect"
                        iconText: root.connecting ? "󰔟" : "󰖂"
                        iconSpinning: root.connecting
                        foreground: root.barForeground
                        accent: Color.accent
                        selected: true
                        bordered: true
                        enabled: !root.connecting
                        onClicked: root.startConnection()
                    }

                }

            }

            ColumnLayout {
                visible: root.connected
                Layout.fillWidth: true
                spacing: Style.space(12)

                Text {
                    text: "ACTIVE SESSION"
                    color: root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.1
                }

                SessionRow {
                    icon: "󰩟"
                    label: "Client IP"
                    value: String(root.vpn.clientIp || "—")
                }

                SessionRow {
                    icon: "󰈀"
                    label: "Received"
                    value: root.humanBytes(root.vpn.receivedBytes)
                }

                SessionRow {
                    icon: "󰕒"
                    label: "Sent"
                    value: root.humanBytes(root.vpn.sentBytes)
                }

                SessionRow {
                    icon: "󰔛"
                    label: "Duration"
                    value: root.humanDuration(root.vpn.durationSec)
                }

                SessionRow {
                    icon: "󰛳"
                    label: "Interface"
                    value: String(root.vpn.interface || "PPP")
                }

                Item {
                    Layout.fillHeight: true
                    Layout.minimumHeight: Style.space(4)
                }

                RowLayout {
                    Layout.fillWidth: true

                    Item {
                        Layout.fillWidth: true
                    }

                    Button {
                        text: "Disconnect"
                        iconText: "󰅖"
                        foreground: root.barForeground
                        bordered: true
                        onClicked: root.disconnect()
                    }

                }

            }

        }

    }

    PanelWindow {
        id: otpOverlay

        screen: button.QsWindow.window ? button.QsWindow.window.screen : null
        visible: root.otpRequired
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "local-netextender-otp"
        WlrLayershell.layer: WlrLayer.Overlay
        // Remain above normal windows while allowing the user to copy a code
        // from an authenticator or browser and paste it back into this card.
        WlrLayershell.keyboardFocus: root.otpRequired ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        onVisibleChanged: {
            if (visible)
                Qt.callLater(function() {
                otpField.forceActiveFocus();
            });

        }

        anchors {
            top: true
            right: true
            bottom: true
            left: true
        }

        BorderSurface {
            id: otpCard

            width: Math.min(Style.space(430), otpOverlay.width - Style.space(32))
            height: otpContent.implicitHeight + Style.space(40)
            anchors.centerIn: parent
            color: Color.popups.background
            borderSpec: Border.controlSpec("focus", root.barForeground, Color.accent)
            radius: Style.cornerRadius

            ColumnLayout {
                id: otpContent

                anchors.fill: parent
                anchors.margins: Style.space(20)
                spacing: Style.space(12)

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "󰌆"
                    color: Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.space(32)
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Two-factor authentication"
                    color: root.barForeground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                }

                Text {
                    Layout.fillWidth: true
                    text: "Please get the code from your bind App. And enter the code below."
                    color: root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                }

                TextField {
                    id: otpField

                    Layout.fillWidth: true
                    foreground: root.barForeground
                    password: true
                    placeholderText: "Verification code"
                    inputMethodHints: Qt.ImhDigitsOnly
                    onAccepted: root.submitOtp()
                }

                RowLayout {
                    Layout.fillWidth: true

                    Item {
                        Layout.fillWidth: true
                    }

                    Button {
                        text: "Cancel"
                        foreground: root.barForeground
                        bordered: true
                        onClicked: root.disconnect()
                    }

                    Button {
                        text: "Verify"
                        iconText: "󰄬"
                        foreground: root.barForeground
                        selected: true
                        bordered: true
                        onClicked: root.submitOtp()
                    }

                }

            }

        }

        // The transparent area is click-through; only the card receives
        // pointer input, so other apps remain usable while the code is shown.
        mask: Region {
            item: otpCard
        }

    }

    component FormRow: RowLayout {
        property string label: ""

        Layout.fillWidth: true
        spacing: Style.space(10)

        Text {
            Layout.preferredWidth: Style.space(78)
            text: parent.label + ":"
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignRight
        }

    }

    component SessionRow: RowLayout {
        property string icon: ""
        property string label: ""
        property string value: ""

        Layout.fillWidth: true
        spacing: Style.space(10)

        Text {
            text: parent.icon
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.icon
        }

        Text {
            Layout.fillWidth: true
            text: parent.label
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.body
        }

        Text {
            text: parent.value
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
        }

    }

}
