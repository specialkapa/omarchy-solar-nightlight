import QtQuick
import Quickshell
import Quickshell.Io

// Runs the solar-nightlight daemon for as long as the plugin is enabled and
// restarts it 5s after any exit.
Item {
  id: root
  property var manifest: null
  property var shell: null

  readonly property string daemonPath: String(Qt.resolvedUrl("bin/solar-nightlight")).replace(/^file:\/\//, "")

  Process {
    id: daemonProc
    command: ["python3", "-u", root.daemonPath, "--daemon"]
    running: true
    stdout: SplitParser { onRead: function(line) { console.log(line) } }
    stderr: SplitParser { onRead: function(line) { console.warn(line) } }

    onExited: function(exitCode) {
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 5000
    repeat: false
    onTriggered: {
      if (!daemonProc.running) {
        daemonProc.running = true
      }
    }
  }
}
