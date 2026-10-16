pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property string configuredSocketPath: ""
    readonly property string socketPath: configuredSocketPath || Quickshell.env("KCD_SOCKET") || ((Quickshell.env("XDG_RUNTIME_DIR") || "") + "/kcd/kcd.sock")
    property bool watching: false
    property bool watchConnected: false
    property int failures: 0
    property int requestCount: 0

    signal eventReceived(var event)
    signal watchStateChanged(bool connected)

    onSocketPathChanged: {
        if (watching) {
            stopWatch();
            startWatch();
        }
    }

    function request(command, payload, callback, timeoutMs) {
        if (requestCount >= 8) {
            callback?.({ error: "Too many kcd requests are already active" });
            return;
        }
        requestCount++;
        const item = requestComponent.createObject(root, {
            command: command,
            payload: payload || {},
            callback: callback,
            timeoutMs: timeoutMs || 5000
        });
        if (!item) {
            requestCount--;
            callback?.({ error: "Could not create kcd connection" });
        }
    }

    function finish(item, response) {
        if (!item || item.finished)
            return;
        item.finished = true;
        requestCount = Math.max(0, requestCount - 1);
        item.timer.stop();
        item.socket.connected = false;
        item.callback?.(response);
        item.destroy();
    }

    function startWatch() {
        if (watching) {
            watchObject?.reconnect();
            return;
        }
        watching = true;
        watchComponent.createObject(root);
    }

    function stopWatch() {
        watching = false;
        watchRetry.stop();
        const oldWatch = watchObject;
        watchObject = null;
        oldWatch?.close();
        oldWatch?.destroy();
        setWatchConnected(false);
    }

    function setWatchConnected(value) {
        if (watchConnected === value)
            return;
        watchConnected = value;
        watchStateChanged(value);
    }

    function watchLost() {
        setWatchConnected(false);
        if (!watching || watchRetry.running)
            return;
        watchRetry.interval = Math.min(30000, 500 * Math.pow(2, Math.min(failures++, 6))) + Math.random() * 350;
        watchRetry.start();
    }

    property var watchObject: null
    Timer {
        id: watchRetry
        repeat: false
        onTriggered: root.startWatch()
    }

    Component {
        id: requestComponent
        Item {
            id: requestObject
            width: 0
            height: 0
            visible: false
            property string command
            property var payload
            property var callback
            property int timeoutMs: 5000
            property bool finished: false

            Socket {
                id: requestSocket
                path: root.socketPath
                connected: true
                parser: SplitParser {
                    onRead: line => {
                        let response;
                        try {
                            response = JSON.parse(line);
                        } catch (error) {
                            root.finish(requestObject, { error: "Malformed response from kcd" });
                            return;
                        }
                        if (!response || typeof response.ok !== "boolean") {
                            root.finish(requestObject, { error: "Invalid response from kcd" });
                            return;
                        }
                        root.finish(requestObject, response.ok ? { success: true, result: response.data } : { error: response.error || "kcd request failed" });
                    }
                }
                onConnectedChanged: {
                    if (connected) {
                        write(JSON.stringify({ cmd: requestObject.command, payload: requestObject.payload }) + "\n");
                        flush();
                    } else if (!requestObject.finished) {
                        root.finish(requestObject, { error: "Connection to kcd was lost" });
                    }
                }
                onError: error => root.finish(requestObject, { error: "Could not connect to kcd" })
            }
            property var socket: requestSocket
            Timer {
                id: requestTimer
                interval: requestObject.timeoutMs
                repeat: false
                running: true
                onTriggered: root.finish(requestObject, { error: "kcd request timed out" })
            }
            property var timer: requestTimer
        }
    }

    Component {
        id: watchComponent
        Item {
            id: watchItem
            width: 0
            height: 0
            visible: false
            property bool acknowledged: false
            Socket {
                id: watchSocket
                path: root.socketPath
                connected: root.watching
                parser: SplitParser {
                    onRead: line => {
                        let message;
                        try {
                            message = JSON.parse(line);
                        } catch (error) {
                            watchSocket.connected = false;
                            root.watchLost();
                            return;
                        }
                        if (!watchItem.acknowledged) {
                            if (!message || message.ok !== true) {
                                watchSocket.connected = false;
                                root.watchLost();
                                return;
                            }
                            watchItem.acknowledged = true;
                            root.failures = 0;
                            root.setWatchConnected(true);
                            return;
                        }
                        if (message && typeof message.type === "string")
                            root.eventReceived(message);
                    }
                }
                onConnectedChanged: {
                    if (connected) {
                        write(JSON.stringify({ cmd: "watch", payload: {} }) + "\n");
                        flush();
                    } else {
                        root.watchLost();
                    }
                }
                onError: error => {
                    watchSocket.connected = false;
                    root.watchLost();
                }
            }
            function reconnect() {
                acknowledged = false;
                watchSocket.connected = true;
            }
            function close() {
                watchSocket.connected = false;
            }
            Component.onCompleted: root.watchObject = watchItem
            Component.onDestruction: {
                if (root.watchObject === watchItem)
                    root.watchObject = null;
            }
        }
    }
}
