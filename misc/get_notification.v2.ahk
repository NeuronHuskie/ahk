#Requires Autohotkey v2.0+
#SingleInstance Force
; ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
;   required libraries
; ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
#include <UIA\UIA.v2>    ; https://github.com/Descolada/UIA-v2
; ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■



/**
 * Waits for a Windows toast notification and returns its parsed notification data.
 *
 * Requires Descolada's UIA-v2 library:
 * https://github.com/Descolada/UIA-v2
 *
 * Uses UIA to listen for newly opened toast notification windows with specified timeout period.
 * Optional sender app filter can be applied
 *
 * @param {Integer} timeout_ms  - Time to wait (in milliseconds) for a matching notification.
 * @param {String} app_filter   - Optional app name filter. When provided only notifications whose app name contains this text are returned.
 * @returns {Object|Boolean}    - Found? => { `app`, `from`, `message` } | Not found? => false
 */
get_notification(timeout_ms:=30000, app_filter:='') {
    start_time  := A_TickCount
    state       := { data: '', received: false, filter: app_filter }
    callback    := (sender, *) => parse_notification(state, sender)
    handler     := UIA.CreateEventHandler(callback)
    root        := UIA.GetRootElement()

    UIA.AddAutomationEventHandler(handler, root, UIA.Event.Window_WindowOpened)
    OnExit((*)  => UIA.RemoveAllEventHandlers())
    
    while (!state.received && (A_TickCount - start_time) < timeout_ms)
        Sleep(50)
    
    try UIA.RemoveAutomationEventHandler(handler, root, UIA.Event.Window_WindowOpened)
    
    return state.received ? state.data : false
    
    ; ╭─────────────────────────────────────────────────────╮ 
    ; │   extracts notification data from the uia element   │ 
    ; ╰─────────────────────────────────────────────────────╯ 
    
    parse_notification(state, sender) {
        try {
            if (sender.a != 'NormalToastView')
                return
            
            app     := sender.FindElement({ a: 'SenderName' }).name
            from    := sender.FindElement({ a: 'Title', mm: 2 }).name
            message := sender.FindElement({ a: 'MessageText', mm: 2 }).name
            
            if (state.filter != '' && !InStr(app, state.filter))
                return
            
            state.data      := { app: app, from: from, message: message }
            state.received  := true
        }
    }
}