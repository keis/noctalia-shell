import QtQuick
import Quickshell
import Quickshell.I3
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  // Properties that match the facade interface
  property ListModel workspaces: ListModel {}
  property var windows: []
  property int focusedWindowIndex: -1

  // Signals that match the facade interface
  signal workspaceChanged
  signal activeWindowChanged
  signal windowListChanged

  // I3-specific properties
  property bool initialized: false
  property var workspaceCache: ({})
  property var windowCache: ({})

  // Debounce timer for updates
  Timer {
    id: updateTimer
    interval: 50
    repeat: false
    onTriggered: safeUpdate()
  }

  // Initialization
  function initialize() {
    if (initialized)
      return

    try {
      I3.refreshWorkspaces()
      Qt.callLater(() => {
                     safeUpdateWorkspaces()
                   })
      initialized = true
      Logger.log("I3Service", "Initialized successfully")
    } catch (e) {
      Logger.error("I3Service", "Failed to initialize:", e)
    }
  }

  // Safe update wrapper
  function safeUpdate() {
    safeUpdateWindows()
    safeUpdateWorkspaces()
    windowListChanged()
  }

  // Safe workspace update
  function safeUpdateWorkspaces() {
    try {
      workspaces.clear()
      workspaceCache = {}

      if (!I3.workspaces || !I3.workspaces.values) {
        return
      }

      const hlWorkspaces = I3.workspaces.values
      const occupiedIds = getOccupiedWorkspaceIds()

      for (var i = 0; i < hlWorkspaces.length; i++) {
        const ws = hlWorkspaces[i]
        if (!ws || ws.id < 1)
          continue

        const wsData = {
          "id": i,
          "idx": ws.id,
          "name": ws.name || "",
          "output": (ws.monitor && ws.monitor.name) ? ws.monitor.name : "",
          "isActive": ws.active === true,
          "isFocused": ws.focused === true,
          "isUrgent": ws.urgent === true,
          "isOccupied": occupiedIds[ws.id] === true
        }

        workspaceCache[ws.id] = wsData
        workspaces.append(wsData)
      }
    } catch (e) {
      Logger.error("I3Service", "Error updating workspaces:", e)
    }
  }

  // Get occupied workspace IDs safely
  function getOccupiedWorkspaceIds() {
    const occupiedIds = {}

    try {
      if (!I3.toplevels || !I3.toplevels.values) {
        return occupiedIds
      }

      const hlToplevels = I3.toplevels.values
      for (var i = 0; i < hlToplevels.length; i++) {
        const toplevel = hlToplevels[i]
        if (!toplevel)
          continue

        try {
          const wsId = toplevel.workspace ? toplevel.workspace.id : null
          if (wsId !== null && wsId !== undefined) {
            occupiedIds[wsId] = true
          }
        } catch (e) {

          // Ignore individual toplevel errors
        }
      }
    } catch (e) {

      // Return empty if we can't determine occupancy
    }

    return occupiedIds
  }

  // Safe window update
  function safeUpdateWindows() {
    Logger.warn("I3Service", "Safe update windows")
    try {
      const windowsList = []
      windowCache = {}

      if (!ToplevelManager.toplevels || !ToplevelManager.toplevels.values) {
        windows = []
        focusedWindowIndex = -1
        return
      }

      const hlToplevels = ToplevelManager.toplevels.values
      let newFocusedIndex = -1

      for (var i = 0; i < hlToplevels.length; i++) {
        const toplevel = hlToplevels[i]
        if (!toplevel)
          continue

        const windowData = extractWindowData(toplevel)
        if (windowData) {
          windowsList.push(windowData)
          windowCache[windowData.id] = windowData

          if (windowData.isFocused) {
            newFocusedIndex = windowsList.length - 1
          }
        }
      }

      windows = windowsList

      if (newFocusedIndex !== focusedWindowIndex) {
        Logger.warn("Focused index differs")
        focusedWindowIndex = newFocusedIndex
        activeWindowChanged()
      } else {
        Logger.warn("Focused index is the same", newFocusedIndex)
      }
    } catch (e) {
      Logger.error("I3Service", "Error updating windows:", e)
    }
  }

  // Extract window data safely from a toplevel
  function extractWindowData(toplevel) {
    if (!toplevel)
      return null

    try {
      Logger.warn("I3Service", "Got a toplevel", toplevel)
      // Safely extract properties

      const appId = extractAppId(toplevel)
      const title = safeGetProperty(toplevel, "title", "")
      const wsId = toplevel.workspace ? toplevel.workspace.id : null
      const focused = toplevel.activated === true

      return {
        "id": -1,
        "title": title,
        "appId": appId,
        "workspaceId": wsId,
        "isFocused": focused
      }
    } catch (e) {
      Logger.warn("I3Service", "Borked toplevel", e)
      return null
    }
  }

  // Extract app ID from various possible sources
  function extractAppId(toplevel) {
    if (!toplevel)
      return ""

    // Try direct properties
    var appId = safeGetProperty(toplevel, "class", "")
    if (appId)
      return appId

    appId = safeGetProperty(toplevel, "initialClass", "")
    if (appId)
      return appId

    appId = safeGetProperty(toplevel, "appId", "")
    if (appId)
      return appId

    // Try lastIpcObject
    try {
      const ipcData = toplevel.lastIpcObject
      if (ipcData) {
        return String(ipcData.class || ipcData.initialClass || ipcData.appId || ipcData.wm_class || "")
      }
    } catch (e) {

      // Ignore IPC errors
    }

    return ""
  }

  // Safe property getter
  function safeGetProperty(obj, prop, defaultValue) {
    try {
      const value = obj[prop]
      if (value !== undefined && value !== null) {
        return String(value)
      }
    } catch (e) {

      // Property access failed
    }
    return defaultValue
  }

  // Connections to I3
  Connections {
    target: I3
    enabled: initialized
    function onRawEvent(event) {
      safeUpdateWorkspaces()
      workspaceChanged()
      updateTimer.restart()
    }
  }

  Connections {
    target: ToplevelManager
    enabled: initialized
    function onActiveToplevelChanged() {
      updateTimer.restart()
    }
  }

  // Public functions
  function switchToWorkspace(workspaceId) {
    try {
      I3.dispatch(`workspace ${workspaceId}`)
    } catch (e) {
      Logger.error("I3Service", "Failed to switch workspace:", e)
    }
  }

  function focusWindow(windowId) {
    try {
      I3.dispatch(`focuswindow ${windowId}`)
    } catch (e) {
      Logger.error("I3Service", "Failed to switch window:", e)
    }
  }

  function closeWindow(windowId) {
    try {
      I3.dispatch(`killwindow ${windowId}`)
    } catch (e) {
      Logger.error("I3Service", "Failed to close window:", e)
    }
  }
}
