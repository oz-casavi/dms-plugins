pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

Singleton {
    id: root

    property bool available: false
    property bool initialized: false
    property bool isRefreshing: false
    property bool active: false
    readonly property bool supportsSms: true
    readonly property bool supportsSmsApp: false
    property var deviceIds: []
    property var devices: ({})
    property string announcedName: "kcd"
    property string selfId: ""
    readonly property var connectedDevices: deviceIds.map(id => devices[id]).filter(device => device?.isReachable)
    readonly property var pairedDevices: deviceIds.map(id => devices[id]).filter(device => device?.isPaired)
    readonly property int connectedCount: connectedDevices.length
    readonly property int pairedCount: pairedDevices.length

    signal devicesListChanged
    signal deviceUpdated(string deviceId)
    signal deviceAdded(string deviceId)
    signal deviceRemoved(string deviceId)
    signal pairingRequestReceived(string deviceId, string verificationKey)
    signal shareReceived(string deviceId, string url)

    Timer {
        id: discoveryTimer
        interval: 30000
        repeat: false
        onTriggered: root.stopDiscovery()
    }

    onActiveChanged: {
        if (!active) {
            stopDiscovery();
            KcdTransport.stopWatch();
            available = false;
            initialized = false;
            return;
        }
        KcdTransport.startWatch();
        KcdTransport.request("status", {}, response => {
            available = !response.error;
            if (available)
                refreshDevices();
        });
    }

    Component.onDestruction: KcdTransport.stopWatch()

    Connections {
        target: KcdTransport
        function onEventReceived(event) {
            if (event.type === "state.snapshot") {
                const incoming = event.payload?.devices || [];
                const next = {};
                for (const device of incoming)
                    next[device.id] = root.normalizeDevice(device);
                root.applyDevices(next);
                root.initialized = true;
                root.available = true;
                return;
            }
            const id = event.deviceId || event.payload?.id;
            if (!id)
                return;
            if (event.type === "pair.requested") {
                root.pairingRequestReceived(id, event.payload?.verificationKey || "");
                root.refreshDevices();
                return;
            }
            if (event.type === "device.disconnected") {
                const current = root.devices[id];
                if (current) {
                    const next = Object.assign({}, root.devices);
                    next[id] = Object.assign({}, current, { isReachable: false });
                    root.applyMedia(next[id], null, 0);
                    root.devices = next;
                    root.deviceUpdated(id);
                }
                return;
            }
            if (event.type === "device.removed") {
                const next = Object.assign({}, root.devices);
                delete next[id];
                root.applyDevices(next);
                return;
            }
            if (event.type === "device.added" || event.type === "device.connected" || event.type.startsWith("pair.")) {
                root.refreshDevices();
                return;
            }
            const current = root.devices[id];
            if (!current)
                return;
            const next = Object.assign({}, root.devices);
            const updated = Object.assign({}, current);
            const data = event.payload || {};
            if (event.type === "battery.update") {
                updated.batteryCharge = data.charge ?? -1;
                updated.batteryCharging = data.charging ?? false;
            } else if (event.type === "connectivity.update") {
                const strength = data.signalStrengths?.[Object.keys(data.signalStrengths || {})[0]];
                updated.networkType = strength?.networkType || "";
                updated.networkStrength = strength?.signalStrength ?? -1;
            } else if (event.type === "mpris.update") {
                root.applyMedia(updated, data, 0);
            } else if (event.type === "sftp.mounted") {
                updated.sftpMountPoint = data.mountPoint || "";
                updated.sftpMounted = true;
            } else if (event.type === "sftp.unmounted") {
                updated.sftpMountPoint = "";
                updated.sftpMounted = false;
            }
            next[id] = updated;
            root.devices = next;
            root.deviceUpdated(id);
        }
        function onWatchStateChanged(connected) {
            if (!connected) {
                root.initialized = false;
                root.available = false;
                const stale = Object.assign({}, root.devices);
                for (const id in stale) {
                    stale[id] = Object.assign({}, stale[id], { isReachable: false });
                    root.applyMedia(stale[id], null, 0);
                }
                root.devices = stale;
                root.devicesListChanged();
                return;
            }
            root.available = true;
        }
    }

    function normalizeDevice(device) {
        const paired = device.state === "PAIRED";
        const strength = device.signal?.signalStrengths?.[Object.keys(device.signal?.signalStrengths || {})[0]];
        const normalized = {
            id: device.id,
            name: device.name || device.id,
            type: device.type || "phone",
            isReachable: !!device.connected,
            isPaired: paired,
            pairingRequested: device.state === "PAIR_REQUESTED",
            pairingRequestedByPeer: device.state === "PAIR_REQUESTED_BY_PEER",
            batteryCharge: device.battery?.charge ?? -1,
            batteryCharging: device.battery?.charging ?? false,
            networkType: strength?.networkType || "",
            networkStrength: strength?.signalStrength ?? -1,
            sftpMounted: !!device.sftp?.mounted,
            sftpMountPoint: device.sftp?.mountPoint || "",
            media: null,
            supportedPlugins: []
        };
        root.applyMedia(normalized, device.media, device.media?.mediaAgeMs ?? 0);
        return normalized;
    }

    function applyMedia(device, media, ageMs) {
        if (!media || ageMs > 30000) {
            device.mediaTitle = "";
            device.mediaArtist = "";
            device.mediaAlbum = "";
            device.mediaPlayer = "";
            device.mediaArtUrl = "";
            device.media = null;
            return;
        }
        device.mediaTitle = media.title || "";
        device.mediaArtist = media.artist || "";
        device.mediaAlbum = media.album || "";
        device.mediaPlayer = media.player || "";
        device.mediaArtUrl = media.albumArtUrl || "";
        device.media = media;
    }

    function applyDevices(next) {
        const oldIds = deviceIds;
        for (const id of oldIds) {
            if (!(id in next))
                deviceRemoved(id);
        }
        devices = next;
        deviceIds = Object.keys(next);
        for (const id of deviceIds) {
            if (!oldIds.includes(id))
                deviceAdded(id);
            else
                deviceUpdated(id);
        }
        devicesListChanged();
    }

    function refreshDevices() {
        isRefreshing = true;
        KcdTransport.request("devices", {}, response => {
            isRefreshing = false;
            if (response.error)
                return;
            const next = {};
            for (const device of (response.result || []))
                next[device.id] = normalizeDevice(device);
            applyDevices(next);
            initialized = true;
            available = true;
        });
    }

    function activate() {
        active = true;
    }

    function startDiscovery(callback) {
        if (discoveryTimer.running) {
            callback?.({ success: true });
            return;
        }
        action("broadcast_start", {}, response => {
            if (!response.error && root.active)
                discoveryTimer.start();
            else if (!response.error)
                action("broadcast_stop", {}, () => {});
            callback?.(response);
        });
    }

    function stopDiscovery() {
        const wasRunning = discoveryTimer.running;
        discoveryTimer.stop();
        if (wasRunning)
            action("broadcast_stop", {}, () => {});
    }

    function action(command, payload, callback, timeout) {
        KcdTransport.request(command, payload, callback, timeout);
    }
    function ringDevice(id, callback) { action("findmyphone", { deviceId: id }, callback); }
    function sendPing(id, message, callback) { action("ping", { deviceId: id }, callback); }
    function sendClipboard(id, callback) { action("clipboard_push", { deviceId: id }, callback); }
    function requestPairing(id, callback) { action("pair", { deviceId: id }, callback); }
    function acceptPairing(id, callback) { action("pair", { deviceId: id, accept: true }, callback); }
    function cancelPairing(id, callback) { action("unpair", { deviceId: id }, callback); }
    function unpair(id, callback) { cancelPairing(id, callback); }
    function setLocked(id, locked, callback) { action(locked ? "lock" : "unlock", { deviceId: id }, callback); }
    function getRemoteCommands(id, callback) { action("run_list", { deviceId: id }, r => callback?.(r.error ? [] : (r.result || [])), 12000); }
    function triggerRemoteCommand(id, key, callback) { action("run_exec", { deviceId: id, key: key }, callback); }
    function mprisAction(id, act, callback) { action("mpris_action", { deviceId: id, action: act }, callback); }
    function getMprisPlayers(id, callback) { action("mpris_remote", { deviceId: id }, r => callback?.(r.error ? [] : (r.result?.players || []))); }
    function mountSftp(id, callback) {
        action("sftp_mount_local", { deviceId: id }, response => {
            const path = response.result?.path || "";
            if (!response.error && path) {
                const next = Object.assign({}, devices);
                next[id] = Object.assign({}, next[id], { sftpMounted: true, sftpMountPoint: path });
                devices = next;
                deviceUpdated(id);
            }
            callback?.(response);
        }, 30000);
    }
    function unmountSftp(id, callback) {
        action("sftp_unmount", { deviceId: id }, response => {
            if (!response.error && devices[id]) {
                const next = Object.assign({}, devices);
                next[id] = Object.assign({}, next[id], { sftpMounted: false, sftpMountPoint: "" });
                devices = next;
                deviceUpdated(id);
            }
            callback?.(response);
        });
    }
    function mountAndWait(id, callback) { mountSftp(id, r => callback?.(!r.error && !!r.result?.path)); }
    function startBrowsing(id, callback) {
        mountSftp(id, response => {
            const path = response.result?.path || "";
            if (response.error || !path.startsWith("/")) {
                callback?.(response.error ? response : { error: "kcd returned an invalid phone storage path" });
                return;
            }
            const encodedPath = path.split("/").map(segment => encodeURIComponent(segment)).join("/");
            Qt.callLater(() => {
                const opened = Qt.openUrlExternally("file://" + encodedPath);
                callback?.(opened ? response : { error: "Could not open the phone storage in a file manager" });
            });
        });
    }
    function browseDevice(id, callback) {
        mountSftp(id, response => {
            const path = response.result?.path || "";
            callback?.(!response.error && !!path, path);
        });
    }
    function getSftpMountPoint(id, callback) { callback?.(devices[id]?.sftpMountPoint || ""); }
    function isSftpMounted(id, callback) { getSftpMountPoint(id, path => callback?.(path !== "")); }
    function requestPhoto(id, path, callback) { callback?.({ error: "kcd does not support camera requests" }); }
    function shareUrl(id, url, callback) {
        if (!url?.startsWith("file://")) {
            callback?.({ error: "kcd does not support URL sharing" });
            return;
        }
        shareFile(id, url, callback);
    }
    function shareText(id, text, callback) { callback?.({ error: "kcd does not support text sharing" }); }
    function shareFile(id, fileUrl, callback) {
        if (!fileUrl?.startsWith("file://")) {
            callback?.({ error: "kcd can only send local files" });
            return;
        }
        let path;
        try {
            path = decodeURIComponent(fileUrl.substring(7));
        } catch (error) {
            callback?.({ error: "Invalid local file URL" });
            return;
        }
        if (!path.startsWith("/")) {
            callback?.({ error: "Invalid local file URL" });
            return;
        }
        action("share", { deviceId: id, filePath: path }, callback);
    }
    function sendSms(id, addresses, message, attachments, callback) {
        const numbers = Array.isArray(addresses) ? addresses : [addresses];
        if (numbers.length !== 1 || attachments?.length || !numbers[0]) {
            callback?.({ error: "kcd supports one SMS recipient and no attachments" });
            return;
        }
        action("send_sms", { deviceId: id, phoneNumber: numbers[0], message: message }, callback);
    }
    function launchSmsApp(id, callback) { callback?.({ error: "kcd has no SMS application to launch" }); }
    function getConversations(id, callback) { callback?.({ error: "kcd conversation retrieval is unavailable" }); }
}
