#Requires Autohotkey v2.0+
#WinActivateForce
#SingleInstance Force
; ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
#include <WebView2\WebView2.v2> ; https://github.com/thqby/ahk2_lib/tree/master/WebView2
#include <JSON\cJSON.v2> ; https://github.com/G33kDude/cJson.ahk
; ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■

/**
 * JSON Hero-style viewer for hierarchical data using WebView2.
 * 
 * @param {String|Object|Map|Array} json_input - Data to display. Accepts:
 *   - JSON string: `'{"key": "value"}'`
 *   - File path: `'C:\path\to\file.json'` (auto-detected if file exists)
 *   - AHK Object/Map/Array: `Map('key', 'value')` (auto-converted to JSON)
 * 
 * @param {Object} [options] - Configuration options
 * @param {Number} [options.width] - Window width in pixels (default: 70% of screen width)
 * @param {Number} [options.height] - Window height in pixels (default: 70% of screen height)
 * @param {String} [options.title='json viewer [ahk]'] - Window title
 * @param {String} [options.view='tree'] - Initial view mode: 'tree', 'column', or 'json'
 * @param {Boolean} [options.submit_on_enter=false] - If true, pressing Enter returns the selected node and closes the viewer
 * 
 * @returns {Object} Result object with properties:
 *   - `selected` {Any} - The selected value when submit_on_enter is true and Enter was pressed, otherwise empty string
 * 
 * @example
 * ; basic usage with a Map
 * json_viewer(Map('name', 'John', 'age', 30))
 * 
 * @example
 * ; view a JSON file with custom title
 * json_viewer('C:\data\config.json', {title: 'Config Viewer'})
 * 
 * @example
 * ; get selected value on Enter
 * result := json_viewer(my_data, {submit_on_enter: true})
 * if result.selected != ''
 *     MsgBox('Selected: ' String(result.selected))
 * 
 * @example
 * ; custom window size and column view
 * json_viewer(api_response, {
 *     width: 1400,
 *     height: 900,
 *     title: 'API Response',
 *     view: 'column'
 * })
 */
json_viewer(json_input, options?) => JSON_VIEWER_CLASS(json_input, options?).result

class JSON_VIEWER_CLASS {
    
    __New(json_input, options?) {
        try TraySetIcon(StrReplace(A_LineFile, '.ahk', '.ico'))
        
        ; register onexit callback
        OnExit(this.exit_handler := ObjBindMethod(this, 'on_close'))

        ; set JSON library options
        JSON.BoolsAsInts := false
        JSON.NullsAsStrings := false

        ; parse options with defaults
        opts := this._parse_options(options?)
        this.gui_width := opts.width
        this.gui_height := opts.height
        this.title := opts.title
        this.view_mode := opts.view
        this.submit_on_enter := opts.submit_on_enter

        ; parse input (object, file path, or json string)
        this.json_string := this._parse_input(json_input)
        this.temp_file := A_Temp '\json_viewer_' A_TickCount '.html'
        this.result := {selected: ''}
        this.dialog_closed := false

        ; create and show gui
        this.g := Gui('+Resize', this.title)
        this.g.BackColor := '0f172a'
        this.g.Show(Format('w{} h{}', this.gui_width, this.gui_height))

        try {
            this._init_webview()
            this._wait_for_result()
        } catch as err {
            MsgBox('Error initializing WebView2: ' err.Message, 'Error', '16')
            this.result := {selected: ''}
            this._cleanup_temp_file()
        }
    }

    __Delete() => this._cleanup_temp_file()

    ; ╭──────────────────────────────────────────────────╮ 
    ; │              initialization helpers              │ 
    ; ╰──────────────────────────────────────────────────╯ 

    _parse_options(options?) {
        defaults := Map(
            'width',           A_ScreenWidth * 0.7,
            'height',          A_ScreenHeight * 0.7,
            'title',           'json viewer [ahk]',
            'view',            'tree',
            'submit_on_enter', false
        )
        
        parsed := {}

        for key, default_value in defaults {
            parsed.%key% := (IsSet(options) && options.HasOwnProp(key)) 
                ? options.%key% 
                : default_value
        }

        return parsed
    }

    _parse_input(json_input) => 
          IsObject(json_input) 
        ? JSON.Dump(json_input) 
        : FileExist(json_input) 
        ? FileRead(json_input, 'UTF-8-RAW') 
        : json_input

    _init_webview() {
        this.wvc := WebView2.CreateControllerAsync(this.g.hwnd).await()
        this.wv  := this.wvc.CoreWebView2

        handlers := Map(          ; register host object handlers
            'copy_handler',       this.handle_copy.Bind(this),
            'open_url_handler',   this.handle_open_url.Bind(this),
            'select_handler',     this.handle_select.Bind(this),
            'save_file_handler',  this.handle_save_file.Bind(this),
            'open_path_handler',  this.handle_open_path.Bind(this),
            'check_path_handler', this.handle_check_path.Bind(this),
            'read_file_handler',  this.handle_read_file.Bind(this),
            'close_handler',      this.handle_close.Bind(this)
        )

        for name, handler in handlers
            this.wv.AddHostObjectToScript(name, handler)

        if this.wv.HasMethod('InjectAhkComponent')
            this.wv.InjectAhkComponent()

        ; gui event handlers
        this.g.OnEvent('Close', this.exit_handler)
        this.g.OnEvent('Size', this.on_resize.Bind(this))

        ; build and navigate to html
        html := this._build_html()
        html ? this.wv.NavigateToString(html)
             : this.wv.Navigate('file:///' StrReplace(this.temp_file, '\', '/'))

        this.wv.add_NavigationCompleted((*) => this.wvc.MoveFocus(0))
    }

    _build_html() {
        ; escape problematic characters
        safe_json := this.json_string
        safe_json := StrReplace(safe_json, Chr(96), '\u0060')           ; backticks
        safe_json := StrReplace(safe_json, '</script>', '<\/script>')   ; script tags
        
        ; build html from template
        html := this._html_template()
        replacements := Map(
            '{{JSON_DATA}}',        safe_json,
            '{{VIEW_MODE}}',        this.view_mode,
            '{{TITLE}}',            this.title,
            '{{SUBMIT_ON_ENTER}}',  this.submit_on_enter
        )

        for placeholder, value in replacements
            html := StrReplace(html, placeholder, value)
        
        ; use temp file for large html (NavigateToString has ~1.5MB limit)
        if StrLen(html) > 1500000 {
            FileAppend(html, this.temp_file, 'UTF-8-RAW')
            return
        }
        
        return html
    }
    
    _wait_for_result() {
        while (!this.dialog_closed && WinExist(this.g.hwnd))
            Sleep(50)
    }

    _cleanup_temp_file() {
        try FileDelete(this.temp_file)
    }

    ; ╭──────────────────────────────────────────────────╮ 
    ; │                gui event handlers                │ 
    ; ╰──────────────────────────────────────────────────╯ 

    on_close(*) {
        if this.exit_handler 
            OnExit(this.exit_handler, 0), this.exit_handler := 0
        
        this.dialog_closed := true
        this._cleanup_temp_file()
        try this.g.Destroy()
    }
    
    on_resize(gui_obj, min_max, width, height) {
        if (min_max != -1)
            try this.wvc.Fill()
    }

    ; ╭───────────────────────────────────────────────────╮ 
    ; │   webview host object handlers (called from js)   │ 
    ; ╰───────────────────────────────────────────────────╯ 

    handle_copy(text) => A_Clipboard := text
    
    handle_open_url(url) => Run(url)

    handle_select(path) {
        try this.result := JSON.Load(path)['value']
        this.dialog_closed := true
        this.g.Destroy()
    }

    handle_open_path(path) {
        if FileExist(path) {    ; open file or folder in explorer/default app
            if InStr(FileExist(path), 'D')
                Run('explorer.exe "' path '"')  ; open folder in explorer
            else
                Run(path)  ; open file with default app
        }
    }

    handle_check_path(path) {
        ; check if path exists and return info
        attr := FileExist(path)
        if !attr
            return ''
        is_dir := InStr(attr, 'D') ? 1 : 0
        try {
            if is_dir {
                return JSON.Dump({exists: true, isDir: true, size: 0, modified: ''})
            } else {
                size := FileGetSize(path)
                modified := FileGetTime(path, 'M')
                return JSON.Dump({exists: true, isDir: false, size: size, modified: modified})
            }
        }
        return JSON.Dump({exists: true, isDir: is_dir, size: 0, modified: ''})
    }

    handle_save_file(json_content, suggested_name := 'export.json') {
        selected_file := FileSelect('S16', suggested_name, 'Save JSON File', 'JSON Files (*.json)') ; show save dialog and save file
        if selected_file {
            if !RegExMatch(selected_file, 'i)\.json$')  ; ensure .json extension
                selected_file .= '.json'
            try FileDelete(selected_file)
            FileAppend(json_content, selected_file, 'UTF-8')
            return selected_file
        }
        return ''
    }
    
    handle_read_file(path, max_bytes := 50000) {
        ; read file contents for preview (text files only, limited size)
        if !FileExist(path)
            return ''
        attr := FileExist(path)
        if InStr(attr, 'D')
            return ''  ; can't read directories
        
        try {
            size := FileGetSize(path)   ; check file size first
            ; determine if binary or text based on extension
            SplitPath(path, , , &ext)
            ext := StrLower(ext)
            
            ; image files - return base64 (limit to 5MB)
            if RegExMatch(ext, 'i)^(png|jpg|jpeg|gif|bmp|webp|ico|svg)$') {
                max_image_bytes := 5000000  ; 5MB limit for images
                if (size > max_image_bytes)
                    return JSON.DUMP({type: 'error', message: 'Image too large (max 5MB)'})
                
                file := FileOpen(path, 'r')
                if !file
                    return ''
                file.Seek(0)
                bytes := Buffer(size)
                file.RawRead(bytes)
                file.Close()
                
                ; convert to base64
                flags := 0x40000001  ; CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF
                DllCall('crypt32\CryptBinaryToStringW', 'Ptr', bytes.Ptr, 'UInt', bytes.Size, 'UInt', flags, 'Ptr', 0, 'UInt*', &b64_len := 0)
                b64 := Buffer(b64_len * 2)
                DllCall('crypt32\CryptBinaryToStringW', 'Ptr', bytes.Ptr, 'UInt', bytes.Size, 'UInt', flags, 'Ptr', b64.Ptr, 'UInt*', &b64_len)
                b64_str := StrGet(b64, 'UTF-16')
                
                mime := ext = 'svg' ? 'image/svg+xml' : (ext = 'png' ? 'image/png' : (ext = 'gif' ? 'image/gif' : (ext = 'webp' ? 'image/webp' : (ext = 'ico' ? 'image/x-icon' : 'image/jpeg'))))
                return JSON.Dump({type: 'image', mime: mime, data: b64_str})
            }
            
            ; audio files - return base64 (limit to 10MB)
            if RegExMatch(ext, 'i)^(mp3|wav|ogg|m4a|flac|aac)$') {
                max_audio_bytes := 10000000  ; 10MB limit for audio
                if (size > max_audio_bytes)
                    return JSON.Dump({type: 'error', message: 'Audio file too large (max 10MB)'})
                
                file := FileOpen(path, 'r')
                if !file
                    return ''
                file.Seek(0)
                bytes := Buffer(size)  ; read full file, not truncated
                file.RawRead(bytes)
                file.Close()
                
                ; convert to base64
                flags := 0x40000001  ; CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF
                DllCall('crypt32\CryptBinaryToStringW', 'Ptr', bytes.Ptr, 'UInt', bytes.Size, 'UInt', flags, 'Ptr', 0, 'UInt*', &b64_len := 0)
                b64 := Buffer(b64_len * 2)
                DllCall('crypt32\CryptBinaryToStringW', 'Ptr', bytes.Ptr, 'UInt', bytes.Size, 'UInt', flags, 'Ptr', b64.Ptr, 'UInt*', &b64_len)
                b64_str := StrGet(b64, 'UTF-16')
                
                mime := ext = 'mp3' ? 'audio/mpeg' : (ext = 'wav' ? 'audio/wav' : (ext = 'ogg' ? 'audio/ogg' : (ext = 'm4a' ? 'audio/mp4' : (ext = 'flac' ? 'audio/flac' : 'audio/aac'))))
                return JSON.Dump({type: 'audio', mime: mime, data: b64_str})
            }
            
            ; text-based files - use the max_bytes limit
            if RegExMatch(ext, 'i)^(txt|md|json|xml|html|htm|css|js|ts|ahk|ah2|py|ps1|bat|cmd|sh|ini|cfg|conf|log|csv|tsv|yaml|yml|toml|sql|vbs|reg|gitignore|env)$') {
                content := FileRead(path, 'UTF-8')
                if (StrLen(content) > max_bytes)
                    content := SubStr(content, 1, max_bytes) . '...[truncated]'
                return JSON.Dump({type: 'text', ext: ext, content: content})
            }
            
            ; unknown file type
            return JSON.Dump({type: 'unknown', ext: ext})
            
        } catch as err {
            return JSON.Dump({type: 'error', message: err.Message})
        }
    }

    handle_close(*) {
        this.dialog_closed := true
        this._cleanup_temp_file()
        this.g.Destroy()
    }
    
    ; ╭──────────────────────────────────────────────────╮ 
    ; │             css / html / js template             │ 
    ; ╰──────────────────────────────────────────────────╯ 

    _html_template() => "
    (
        <!DOCTYPE html>
        <html lang='en'>
        <head>
            <meta charset='UTF-8'>
            <title>{{TITLE}}</title>
            <script src='https://cdn.jsdelivr.net/npm/marked/marked.min.js'></script>
            <link href='https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/themes/prism-tomorrow.min.css' rel='stylesheet' />
            <script src='https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/components/prism-core.min.js'></script>
            <script src='https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/plugins/autoloader/prism-autoloader.min.js'></script>
            <link rel='stylesheet' href='https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined:opsz,wght,FILL,GRAD@20..24,100..700,0..1,-50..200' />
            <style>

            /* █▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀█ */
            /* █                                 css                                  █ */
            /* █▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄█ */

            :root { --bg-primary: #0f172a; --bg-secondary: #1e293b; --bg-tertiary: #334155; --bg-hover: #475569; --bg-selected: #3b82f6; --bg-selected-dim: rgba(59, 130, 246, 0.15); --text-primary: #f8fafc; --text-secondary: #94a3b8; --text-muted: #64748b; --accent: #3b82f6; --border-color: #334155; --font-size-base: 14px; --type-object: #f472b6; --type-array: #a78bfa; --type-string: #7ec699; --type-url: #7ec699; --type-number: #fbbf24; --type-boolean-true: #22c55e; --type-boolean-false: #ef4444; --type-null: #6b7280; --toast-bg: #3b82f6; --tree-depth-0: #94a3b8; --tree-depth-1: #f472b6; --tree-depth-2: #a78bfa; --tree-depth-3: #38bdf8; --tree-depth-4: #7ec699; --tree-depth-5: #fbbf24; --tree-depth-6: #f87171; --tree-depth-7: #fb923c; }

            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { font-family: 'Segoe UI', system-ui, sans-serif; font-size: var(--font-size-base); background: var(--bg-primary); color: var(--text-primary); height: 100vh; display: flex; flex-direction: column; overflow: hidden; }
            body.loading { overflow: hidden; }
            ::-webkit-scrollbar { width: 8px; height: 8px; }
            ::-webkit-scrollbar-track { background: var(--bg-secondary); }
            ::-webkit-scrollbar-thumb { background: var(--bg-hover); border-radius: 4px; }
            .material-symbols-outlined { font-size: 18px; vertical-align: middle; user-select: none; }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                  loading overlay                 ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .loading-overlay { position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: var(--bg-primary); display: flex; flex-direction: column; align-items: center; justify-content: center; z-index: 9999; opacity: 1; visibility: visible; transition: opacity 0.3s ease, visibility 0.3s ease; }
            .loading-overlay.hidden { opacity: 0; visibility: hidden; pointer-events: none; }
            .loading-spinner { width: 48px; height: 48px; border: 4px solid var(--bg-tertiary); border-top-color: var(--accent); border-radius: 50%; animation: spin 1s linear infinite; }
            .loading-text { margin-top: 1rem; color: var(--text-secondary); font-size: 0.9rem; }
            @keyframes spin { to { transform: rotate(360deg); } }
            .app-content { display: none; flex-direction: column; flex: 1; overflow: hidden; }
            .app-content.ready { display: flex; }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                      header                      ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .header { display: flex; align-items: center; padding: 0.4rem 0.75rem; background: var(--bg-secondary); border-bottom: 1px solid var(--border-color); gap: 0.6rem; flex-shrink: 0; }
            .logo { display: flex; align-items: center; gap: 0.4rem; font-weight: 600; font-size: 0.9rem; }
            .view-switcher { display: flex; background: var(--bg-primary); border-radius: 4px; padding: 2px; gap: 1px; }
            .view-btn { padding: 0.25rem 0.5rem; font-size: 0.75rem; background: transparent; color: var(--text-secondary); border: none; border-radius: 3px; cursor: pointer; display: flex; align-items: center; gap: 4px; }
            .view-btn:hover { background: var(--bg-tertiary); color: var(--text-primary); }
            .view-btn.active { background: var(--accent); color: white; }
            .header-actions { display: flex; gap: 0.3rem; margin-left: auto; }
            .header-btn { padding: 0.25rem 0.6rem; font-size: 0.75rem; background: var(--bg-primary); color: var(--text-secondary); border: 1px solid var(--border-color); border-radius: 4px; cursor: pointer; display: flex; align-items: center; gap: 4px; }
            .header-btn:hover { background: var(--bg-tertiary); color: var(--text-primary); }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                path bar (above panels)           ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .path-bar { padding: 0.5rem 0.75rem; background: var(--bg-secondary); border-bottom: 1px solid var(--border-color); display: flex; align-items: center; gap: 0.3rem; overflow-x: auto; flex-shrink: 0; min-height: 40px; }
            .path-bar::-webkit-scrollbar { height: 4px; }
            .path-nav-btn { padding: 0.25rem; background: transparent; color: var(--text-muted); border: none; border-radius: 4px; cursor: pointer; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
            .path-nav-btn:hover:not(:disabled) { background: var(--bg-tertiary); color: var(--text-primary); }
            .path-nav-btn:disabled { opacity: 0.3; cursor: not-allowed; }
            .path-segments { display: flex; align-items: center; gap: 0.2rem; flex: 1; overflow-x: auto; }
            .path-segment { display: flex; align-items: center; gap: 0.3rem; padding: 0.25rem 0.5rem; background: var(--bg-tertiary); border-radius: 4px; cursor: pointer; white-space: nowrap; font-size: 0.85rem; color: var(--text-secondary); transition: all 0.15s ease; }
            .path-segment:hover { background: var(--bg-hover); color: var(--text-primary); }
            .path-segment.active { background: var(--accent); color: white; }
            .path-segment .material-symbols-outlined { font-size: 16px; }
            .path-separator { color: var(--text-muted); font-size: 16px; flex-shrink: 0; }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                   main layout                    ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .main-container { flex: 1; display: flex; overflow: hidden; position: relative; }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                      panels                      ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .nav-panel { flex: 0 0 auto; width: 550px; min-width: 200px; display: flex; flex-direction: column; overflow: hidden; height: 100%; }
            .preview-panel { flex: 1; min-width: 200px; display: flex; flex-direction: column; overflow: hidden; height: 100%; }
            .panel-header { padding: 0.4rem 0.6rem; font-size: 0.7rem; font-weight: 600; text-transform: uppercase; color: var(--text-muted); background: var(--bg-secondary); border-bottom: 1px solid var(--border-color); display: flex; align-items: center; gap: 0.4rem; flex-shrink: 0; }
            .panel-header-actions { margin-left: auto; display: flex; gap: 0.3rem; }
            .panel-header-btn { padding: 0.15rem 0.4rem; font-size: 0.7rem; background: var(--bg-primary); color: var(--text-secondary); border: 1px solid var(--border-color); border-radius: 3px; cursor: pointer; display: flex; align-items: center; gap: 3px; }
            .panel-header-btn:hover { background: var(--bg-tertiary); color: var(--text-primary); }
            .panel-content { flex: 1; overflow: auto; min-height: 0; }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║               json mode overrides                ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .container-json-mode .nav-panel { width: 100% !important; flex: 1 !important; }
            .container-json-mode .preview-panel, .container-json-mode .resizer { display: none !important; }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                     resizers                     ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .resizer { width: 6px; background: var(--bg-primary); border-left: 1px solid var(--border-color); border-right: 1px solid var(--border-color); cursor: col-resize; flex-shrink: 0; z-index: 10; display: flex; align-items: center; justify-content: center; }
            .resizer:hover, .resizer.active { background: var(--accent); }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                   column view                    ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .column-view { display: none; flex: 1; overflow-x: auto; overflow-y: hidden; scroll-behavior: smooth; height: 100%; }
            .column-view.active { display: flex; }
            .column { min-width: 50%; max-width: 50%; flex-shrink: 0; display: flex; flex-direction: column; border-right: 1px solid var(--border-color); height: 100%; }
            .column-items { flex: 1; overflow-y: auto; padding: 0.3rem; }
            .column-item { display: flex; align-items: center; padding: 0.15rem 0.3rem; border-radius: 3px; cursor: pointer; gap: 0.2rem; min-height: 28px; }
            .column-item:hover { background: var(--bg-tertiary); }
            .column-item.selected { background: var(--bg-selected-dim); outline: 1px solid var(--accent); }
            .column-item.selected .item-meta { color: var(--text-secondary); }
            .item-content { flex: 1; min-width: 0; display: flex; align-items: center; gap: 0.3rem; }
            .item-key { font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 0.9em; }
            .item-meta { font-size: 0.85em; font-family: 'Cascadia Code', monospace; color: var(--text-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            .item-icon { font-size: 16px; }
            .item-chevron { font-size: 16px; color: var(--text-muted); }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                 type icon colors                 ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .item-icon.object { color: var(--type-object); }
            .item-icon.array { color: var(--type-array); }
            .item-icon.string { color: var(--type-string); }
            .item-icon.url { color: var(--type-string); }
            .item-icon.number { color: var(--type-number); }
            .item-icon.boolean-true { color: var(--type-boolean-true); }
            .item-icon.boolean-false { color: var(--type-boolean-false); }
            .item-icon.null { color: var(--type-null); }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                 item-meta colors                 ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .item-meta.object { color: var(--type-object); }
            .item-meta.array { color: var(--type-array); }
            .item-meta.string { color: var(--type-string); }
            .item-meta.url { color: var(--type-string); }
            .item-meta.number { color: var(--type-number); }
            .item-meta.boolean-true { color: var(--type-boolean-true); }
            .item-meta.boolean-false { color: var(--type-boolean-false); }
            .item-meta.null { color: var(--type-null); }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                node-value colors                 ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .node-value.object { color: var(--type-object); }
            .node-value.array { color: var(--type-array); }
            .node-value.string { color: var(--type-string); }
            .node-value.url { color: var(--type-string); }
            .node-value.number { color: var(--type-number); }
            .node-value.boolean-true { color: var(--type-boolean-true); }
            .node-value.boolean-false { color: var(--type-boolean-false); }
            .node-value.null { color: var(--type-null); }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                    tree view                     ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .tree-view { flex: 1; overflow: auto; padding: 0.3rem; display: none; height: 100%; }
            .tree-view.active { display: block; }
            .node-row { display: flex; align-items: center; padding: 0.15rem 0.3rem; border-radius: 3px; cursor: pointer; gap: 0.2rem; }
            .node-row:hover { background: var(--bg-tertiary); }
            .node-row.selected { background: var(--bg-selected-dim); outline: 1px solid var(--accent); }
            .expand-icon { font-size: 16px; color: var(--text-muted); transition: transform 0.15s; }
            .expand-icon.expanded { transform: rotate(90deg); }
            .expand-icon.leaf { opacity: 0; }
            .node-key { font-weight: 500; font-size: 13px; }
            .node-value { font-family: 'Cascadia Code', monospace; font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            .node-value.string { color: var(--type-string); }
            .node-value.url { color: var(--type-string); }
            .node-value.number { color: var(--type-number); }
            .node-value.boolean { color: var(--type-boolean); }
            .node-value.null { color: var(--type-null); }
            .node-value.object { color: var(--type-object); }
            .node-value.array { color: var(--type-array); }
            .node-children { margin-left: 14px; padding-left: 8px; display: none; position: relative; }
            .node-children.expanded { display: block; }
            .node-children[data-depth='0'] { border-left: 2px solid var(--tree-depth-0); }
            .node-children[data-depth='1'] { border-left: 2px solid var(--tree-depth-1); }
            .node-children[data-depth='2'] { border-left: 2px solid var(--tree-depth-2); }
            .node-children[data-depth='3'] { border-left: 2px solid var(--tree-depth-3); }
            .node-children[data-depth='4'] { border-left: 2px solid var(--tree-depth-4); }
            .node-children[data-depth='5'] { border-left: 2px solid var(--tree-depth-5); }
            .node-children[data-depth='6'] { border-left: 2px solid var(--tree-depth-6); }
            .node-children[data-depth='7'] { border-left: 2px solid var(--tree-depth-7); }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                    json view                     ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .json-view { flex: 1; overflow: auto; display: none; height: 100%; }
            .json-view.active { display: block; }
            pre[class*='language-'] { margin: 0; padding: 1rem; background: transparent !important; text-shadow: none !important; }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                  preview panel                   ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .preview-content { padding: 1rem; overflow: auto; display: flex; flex-direction: column; height: 100%; gap: 1rem; }
            .preview-section { display: flex; flex-direction: column; gap: 0.5rem; }
            .preview-section-collapsible { margin-top: 0.75rem; border-top: 1px solid var(--border-color); padding-top: 0.5rem; }
            .preview-section-collapsible .preview-properties-toggle { margin-bottom: 0.25rem; }
            .preview-section-collapsible.collapsed .preview-section-content { display: none; }
            .preview-section-collapsible.collapsed .preview-properties-toggle .material-symbols-outlined { transform: rotate(-90deg); }
            .preview-section-content { transition: all 0.2s ease; }
            .preview-section-header { font-size: 0.85rem; font-weight: 600; color: var(--text-primary); }
            .preview-item { margin-bottom: 1rem; }
            .preview-label { font-size: 0.75rem; color: var(--text-muted); text-transform: uppercase; margin-bottom: 0.3rem; }
            .preview-raw-wrapper { position: relative; display: inline-block; max-width: 100%; }
            .preview-raw { font-family: 'Cascadia Code', monospace; font-size: 13px; padding: 0.5rem; background: var(--bg-tertiary); border-radius: 4px; word-break: break-all; white-space: pre-wrap; display: block; max-width: 100%; cursor: pointer; transition: background 0.15s ease; }
            .preview-raw:hover { background: var(--bg-hover); }
            .preview-raw.string { color: var(--type-string); }
            .preview-raw.url { color: var(--type-string); }
            .preview-raw.number { color: var(--type-number); }
            .preview-raw.boolean-true { color: var(--type-boolean-true); }
            .preview-raw.boolean-false { color: var(--type-boolean-false); }
            .preview-raw.null { color: var(--type-null); }
            .preview-raw-copy-btn { position: absolute; top: 0.3rem; right: 0.3rem; padding: 0.2rem 0.4rem; font-size: 0.65rem; background: var(--bg-secondary); color: var(--text-secondary); border: 1px solid var(--border-color); border-radius: 3px; cursor: pointer; display: flex; align-items: center; gap: 3px; opacity: 0; transition: opacity 0.15s ease; }
            .preview-raw-wrapper:hover .preview-raw-copy-btn { opacity: 1; }
            .preview-raw-copy-btn:hover { background: var(--accent); color: white; border-color: var(--accent); }
            .preview-code-wrapper { position: relative; }
            .preview-code-wrapper pre { margin: 0; }
            .preview-code-copy-btn { position: absolute; top: 0.5rem; right: 0.5rem; padding: 0.3rem 0.5rem; font-size: 0.7rem; background: var(--bg-secondary); color: var(--text-secondary); border: 1px solid var(--border-color); border-radius: 4px; cursor: pointer; display: flex; align-items: center; gap: 3px; opacity: 0; transition: opacity 0.15s ease; }
            .preview-code-wrapper:hover .preview-code-copy-btn { opacity: 1; }
            .preview-code-copy-btn:hover { background: var(--accent); color: white; border-color: var(--accent); }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║           properties table in preview            ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .preview-properties-section { display: flex; flex-direction: column; }
            .preview-properties-toggle { display: flex; align-items: center; gap: 0.25rem; cursor: pointer; user-select: none; padding: 0.25rem 0; color: var(--text-muted); font-size: 0.7rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.025em; }
            .preview-properties-toggle:hover { color: var(--text-primary); }
            .preview-properties-toggle .material-symbols-outlined { font-size: 16px; transition: transform 0.15s ease; }
            .preview-properties-section.collapsed .preview-properties-toggle .material-symbols-outlined { transform: rotate(-90deg); }
            .preview-properties-table { display: flex; flex-direction: column; border: 1px solid var(--border-color); border-radius: 6px; overflow: hidden; transition: max-height 0.2s ease, opacity 0.2s ease, margin 0.2s ease; max-height: 1000px; opacity: 1; margin-top: 0.25rem; }
            .preview-properties-section.collapsed .preview-properties-table { max-height: 0; opacity: 0; margin-top: 0; border-color: transparent; }
            .preview-prop-row { display: flex; border-bottom: 1px solid var(--border-color); font-size: 0.8rem; }
            .preview-prop-row:last-child { border-bottom: none; }
            .preview-prop-label { flex: 0 0 100px; padding: 0.5rem 0.75rem; background: var(--bg-secondary); color: var(--text-muted); font-weight: 500; border-right: 1px solid var(--border-color); }
            .preview-prop-value { flex: 1; padding: 0.5rem 0.75rem; font-family: 'Cascadia Code', monospace; color: var(--text-primary); cursor: pointer; word-break: break-all; background: var(--bg-primary); transition: background 0.15s ease; }
            .preview-prop-value:hover { background: var(--bg-tertiary); color: var(--accent); }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║              special preview types               ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .preview-url { display: flex; flex-direction: column; gap: 0.5rem; }
            .preview-url-header { display: flex; align-items: center; gap: 0.6rem; }
            .preview-url-icon { font-size: 1.5rem; color: var(--accent); }
            .preview-url-text { color: var(--accent); text-decoration: none; word-break: break-all; cursor: pointer; font-size: 0.9rem; }
            .preview-url-text:hover { text-decoration: underline; }
            .preview-url-actions { display: flex; gap: 0.5rem; }
            .preview-url-btn { padding: 0.4rem 0.8rem; font-size: 0.8rem; background: var(--bg-primary); color: var(--text-secondary); border: 1px solid var(--border-color); border-radius: 4px; cursor: pointer; display: flex; align-items: center; gap: 4px; }
            .preview-url-btn:hover { background: var(--accent); color: white; border-color: var(--accent); }
            .preview-url-embed { border-radius: 6px; overflow: hidden; border: 1px solid var(--border-color); background: #fff; }
            .preview-url-embed iframe { width: 100%; height: 450px; border: none; }
            .preview-url-embed img { max-width: 100%; max-height: 400px; display: block; margin: 0 auto; }
            .preview-url-embed-info { font-size: 0.75rem; color: var(--text-muted); margin-top: 0.3rem; }
            .preview-url-embed-placeholder { display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 2rem; background: var(--bg-primary); color: var(--text-muted); gap: 0.5rem; min-height: 150px; }
            .preview-url-embed-error { display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 1.5rem; background: var(--bg-primary); color: var(--text-muted); gap: 0.5rem; text-align: center; }
            .preview-url-embed-error .material-symbols-outlined { font-size: 2rem; color: var(--type-null); }
            .preview-color { width: 100%; height: 150px; border-radius: 6px; border: 1px solid var(--border-color); display: flex; align-items: center; justify-content: center; font-family: 'Cascadia Code', monospace; font-size: 0.9rem; }
            .preview-date { padding: 0.8rem; background: var(--bg-tertiary); border-radius: 6px; }
            .preview-date-main { font-size: 1.1rem; font-weight: 500; }
            .preview-date-sub { margin-top: 0.3rem; color: var(--text-secondary); }
            .preview-date-calendar { margin-top: 0.75rem; border: 1px solid var(--border-color); border-radius: 6px; overflow: hidden; }
            .preview-date-calendar-header { display: grid; grid-template-columns: repeat(7, 1fr); background: var(--bg-secondary); border-bottom: 1px solid var(--border-color); }
            .preview-date-calendar-header span { padding: 0.4rem; text-align: center; font-size: 0.7rem; font-weight: 600; color: var(--text-muted); }
            .preview-date-calendar-body { display: grid; grid-template-columns: repeat(7, 1fr); }
            .preview-date-calendar-day { padding: 0.5rem; text-align: center; font-size: 0.75rem; color: var(--text-secondary); display: flex; align-items: center; justify-content: center; }
            .preview-date-calendar-day.other-month { color: var(--text-muted); opacity: 0.5; }
            .preview-date-calendar-day.selected { position: relative; }
            .preview-date-calendar-day.selected span { display: flex; align-items: center; justify-content: center; width: 28px; height: 28px; background: var(--accent); color: white; border-radius: 50%; font-weight: 600; }
            .preview-path { display: flex; flex-direction: column; gap: 0.5rem; }
            .preview-path-header { display: flex; align-items: center; gap: 0.6rem; }
            .preview-path-icon { font-size: 1.5rem; color: var(--type-string); }
            .preview-path-label { color: var(--text-muted); font-size: 0.85em; }
            .preview-path-text { font-family: 'Cascadia Code', monospace; font-size: 0.9em; word-break: break-all; }
            .preview-path-actions { display: flex; gap: 0.5rem; }
            .preview-path-btn { padding: 0.4rem 0.8rem; font-size: 0.8rem; background: var(--bg-primary); color: var(--text-secondary); border: 1px solid var(--border-color); border-radius: 4px; cursor: pointer; display: flex; align-items: center; gap: 4px; }
            .preview-path-btn:hover { background: var(--accent); color: white; border-color: var(--accent); }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                  file preview                    ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .file-preview { margin-top: 0.8rem; border-top: 1px solid var(--border-color); padding-top: 0.8rem; display: flex; flex-direction: column; flex: 1; min-height: 0; overflow: auto }
            .file-preview-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 0.5rem; flex-shrink: 0; }
            .file-preview-label { font-size: 0.75rem; color: var(--text-muted); text-transform: uppercase; }
            .file-preview-copy-btn { padding: 0.25rem 0.5rem; font-size: 0.7rem; background: var(--bg-primary); color: var(--text-secondary); border: 1px solid var(--border-color); border-radius: 3px; cursor: pointer; display: flex; align-items: center; gap: 3px; opacity: 0; transition: opacity 0.15s ease; }
            .file-preview:hover .file-preview-copy-btn { opacity: 1; }
            .file-preview-copy-btn:hover { background: var(--accent); color: white; border-color: var(--accent); }
            .file-preview-image { max-width: 100%; max-height: 300px; border-radius: 4px; border: 1px solid var(--border-color); object-fit: contain; }
            .file-preview-code { background: var(--bg-primary); border-radius: 4px; padding: 0.5rem; overflow: auto; font-family: 'Cascadia Code', monospace; font-size: 13px; white-space: pre-wrap; word-break: break-all; flex: 1; min-height: 0; }
            .file-preview-code pre { margin: 0; padding: 0; }
            .file-preview-loading { color: var(--text-muted); font-style: italic; font-size: 0.85em; }
            .file-preview-error { color: var(--type-null); font-size: 0.85em; }
            .markdown-body { padding: 1rem; line-height: 1.7; color: var(--text-primary); background: var(--bg-tertiary); border-radius: 6px; overflow-x: auto; }
            .markdown-body h1 { font-size: 1.8em; margin-top: 0; margin-bottom: 0.75rem; padding-bottom: 0.3rem; border-bottom: 2px solid var(--accent); color: var(--text-primary); }
            .markdown-body h2 { font-size: 1.5em; margin-top: 1.5rem; margin-bottom: 0.5rem; padding-bottom: 0.25rem; border-bottom: 1px solid var(--border-color); color: var(--text-primary); }
            .markdown-body h3 { font-size: 1.25em; margin-top: 1.25rem; margin-bottom: 0.5rem; color: var(--text-primary); }
            .markdown-body h4, .markdown-body h5, .markdown-body h6 { font-size: 1.1em; margin-top: 1rem; margin-bottom: 0.4rem; color: var(--text-secondary); }
            .markdown-body p { margin-bottom: 1rem; }
            .markdown-body ul, .markdown-body ol { margin-left: 1.5rem; margin-bottom: 1rem; padding-left: 0.5rem; }
            .markdown-body li { margin-bottom: 0.25rem; }
            .markdown-body code { background: var(--bg-secondary); padding: 0.2rem 0.4rem; border-radius: 4px; font-family: 'Cascadia Code', 'Consolas', monospace; font-size: 0.9em; color: var(--type-string); }
            .markdown-body pre { background: var(--bg-secondary); padding: 1rem; border-radius: 6px; overflow-x: auto; margin-bottom: 1rem; border: 1px solid var(--border-color); }
            .markdown-body pre code { background: transparent; padding: 0; color: var(--text-primary); font-size: 0.85em; }
            .markdown-body a { color: var(--accent); text-decoration: none; }
            .markdown-body a:hover { text-decoration: underline; }
            .markdown-body blockquote { border-left: 4px solid var(--accent); padding: 0.5rem 1rem; margin: 1rem 0; background: var(--bg-secondary); border-radius: 0 4px 4px 0; color: var(--text-secondary); font-style: italic; }
            .markdown-body strong { font-weight: 600; color: var(--text-primary); }
            .markdown-body em { font-style: italic; }
            .markdown-body hr { border: none; border-top: 1px solid var(--border-color); margin: 1.5rem 0; }
            .markdown-body table { width: 100%; border-collapse: collapse; margin-bottom: 1rem; font-size: 0.9em; }
            .markdown-body th, .markdown-body td { border: 1px solid var(--border-color); padding: 0.5rem 0.75rem; text-align: left; }
            .markdown-body th { background: var(--bg-secondary); font-weight: 600; color: var(--text-primary); }
            .markdown-body tr:nth-child(even) { background: rgba(255, 255, 255, 0.02); }
            .markdown-body img { max-width: 100%; border-radius: 4px; }
            
            /* ╔──────────────────────────────────────────────────╗ */
            /* ║               modern audio player                ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .audio-player-container { display: flex; flex-direction: column; gap: 0.75rem; padding: 1rem; background: linear-gradient(135deg, var(--bg-tertiary) 0%, var(--bg-secondary) 100%); border-radius: 12px; border: 1px solid var(--border-color); }
            .audio-player-header { display: flex; align-items: center; gap: 0.75rem; }
            .audio-player-icon { width: 48px; height: 48px; background: var(--accent); border-radius: 8px; display: flex; align-items: center; justify-content: center; color: white; flex-shrink: 0; }
            .audio-player-icon .material-symbols-outlined { font-size: 24px; }
            .audio-player-info { flex: 1; min-width: 0; }
            .audio-player-title { font-weight: 500; font-size: 0.9rem; color: var(--text-primary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            .audio-player-subtitle { font-size: 0.75rem; color: var(--text-muted); }
            .audio-player-controls { display: flex; align-items: center; gap: 0.75rem; }
            .audio-play-btn { width: 44px; height: 44px; border-radius: 50%; background: var(--accent); border: none; color: white; cursor: pointer; display: flex; align-items: center; justify-content: center; transition: all 0.2s ease; flex-shrink: 0; }
            .audio-play-btn:hover { background: #2563eb; transform: scale(1.05); }
            .audio-play-btn .material-symbols-outlined { font-size: 24px; }
            .audio-progress-container { flex: 1; display: flex; flex-direction: column; gap: 0.25rem; }
            .audio-progress-bar { width: 100%; height: 8px; background: var(--bg-primary); border-radius: 4px; cursor: pointer; overflow: hidden; }
            .audio-progress-fill { height: 100%; background: var(--accent); border-radius: 4px; width: 0%; transition: width 0.1s linear; }
            .audio-time { display: flex; justify-content: space-between; font-size: 0.7rem; color: var(--text-muted); font-family: 'Cascadia Code', monospace; }
            .audio-volume-container { display: flex; align-items: center; gap: 0.4rem; }
            .audio-volume-btn { background: transparent; border: none; color: var(--text-secondary); cursor: pointer; padding: 0.25rem; display: flex; align-items: center; justify-content: center; }
            .audio-volume-btn:hover { color: var(--text-primary); }
            .audio-volume-slider { width: 60px; height: 6px; background: var(--bg-primary); border-radius: 3px; cursor: pointer; overflow: hidden; }
            .audio-volume-fill { height: 100%; background: var(--text-muted); border-radius: 3px; width: 100%; }
            .audio-player-container audio { display: none; }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                    search                        ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .status-bar { padding: 0.3rem 0.75rem; font-size: 0.75rem; background: var(--bg-secondary); color: var(--text-muted); border-top: 1px solid var(--border-color); display: flex; justify-content: space-between; flex-shrink: 0; }
            .search-overlay { position: absolute; top: 10%; left: 50%; transform: translateX(-50%); width: 700px; max-width: 90%; background: var(--bg-primary); border: 2px solid var(--accent); border-radius: 12px; display: none; z-index: 100; flex-direction: column; max-height: 80%; box-shadow: 0 10px 40px rgba(0, 0, 0, 0.5); overflow: hidden; }
            .search-overlay.active { display: flex; }
            .search-input { padding: 0.8rem; background: var(--bg-secondary); border: none; border-bottom: 1px solid var(--border-color); border-radius: 0; color: white; outline: none; font-size: 1rem; }
            .search-results { overflow-y: auto; flex: 1; border-radius: 0; }
            .search-results-count { padding: 0.5rem 0.8rem; font-size: 0.75rem; color: var(--text-muted); border-bottom: 1px solid var(--border-color); background: var(--bg-secondary); }
            .search-result-header { display: flex; align-items: center; gap: 0.4rem; }
            .search-result-path { font-size: 0.8em; color: var(--text-muted); margin-top: 0.2rem; display: flex; align-items: center; flex-wrap: wrap; gap: 0.1rem; }
            .breadcrumb-segment { color: var(--text-secondary); }
            .breadcrumb-sep { color: var(--text-muted); margin: 0 0.1rem; }
            .search-result-item { padding: 0.6rem; cursor: pointer; border-bottom: 1px solid var(--border-color); }
            .search-result-item:hover { background: var(--bg-tertiary); }
            .search-result-item.selected { background: var(--bg-tertiary); border-left: 3px solid var(--accent); }
            .search-result-key { font-weight: 500; }
            .search-result-type { color: var(--text-muted); font-size: 0.85em; margin-left: 0.5rem; }
            .search-result-path { font-size: 0.8em; color: var(--text-muted); margin-top: 0.2rem; }
            .search-result-value { font-size: 0.85em; margin-top: 0.2rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            .search-result-value.boolean-true { color: var(--type-boolean-true); }
            .search-result-value.boolean-false { color: var(--type-boolean-false); }
            .search-result-value.null { color: var(--type-null); }
            .search-result-value.string { color: var(--type-string); }
            .search-result-value.url { color: var(--type-string); }
            .search-result-value.number { color: var(--type-number); }
            .search-result-value.object { color: var(--type-object); }
            .search-result-value.array { color: var(--type-array); }
            .highlight { background: rgba(251, 191, 36, 0.3); color: var(--type-number); border-radius: 2px; padding: 0 2px; }

            /* ╔──────────────────────────────────────────────────╗ */
            /* ║                   context menu                   ║ */
            /* ╚──────────────────────────────────────────────────╝ */

            .context-menu { position: fixed; background: var(--bg-secondary); border: 1px solid var(--border-color); border-radius: 6px; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5); min-width: 180px; z-index: 300; display: none; padding: 0.4rem 0; }
            .context-menu.active { display: block; }
            .context-menu-item { padding: 0.5rem 1rem; cursor: pointer; font-size: 0.85rem; display: flex; align-items: center; gap: 0.6rem; color: var(--text-primary); }
            .context-menu-item:hover { background: var(--bg-hover); }
            .context-menu-separator { height: 1px; background: var(--border-color); margin: 0.3rem 0; }
            .toast { position: fixed; bottom: 40px; left: 50%; transform: translate(-50%, 20px); padding: 0.6rem 1.2rem; background: var(--toast-bg); color: #fff; border-radius: 20px; font-weight: 600; opacity: 0; transition: all 0.3s; pointer-events: none; z-index: 400; display: flex; align-items: center; gap: 0.5rem; box-shadow: 0 5px 15px rgba(0, 0, 0, 0.3); }
            .toast.show { opacity: 1; transform: translate(-50%, 0); }

        </style>
        </head>
        
        <!-- █▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀█ -->
        <!-- █                                 html                                 █ -->
        <!-- █▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄█ -->

        <body class='loading'>
            <div class='loading-overlay' id='loading-overlay'>
                <div class='loading-spinner'></div>
                <div class='loading-text'>Loading...</div>
            </div>

            <div class='app-content' id='app-content'>
                <div class='header'>
                    <div class='logo'><span class='material-symbols-outlined' style='color:var(--accent)'>data_object</span><span>{{TITLE}}</span></div>
                    <div class='view-switcher'>
                        <button class='view-btn' data-view='tree' title='Tree View (1)'><span class='material-symbols-outlined'>account_tree</span></button>
                        <button class='view-btn' data-view='column' title='Column View (2)'><span class='material-symbols-outlined'>view_column</span></button>
                        <button class='view-btn' data-view='json' title='JSON View (3)'><span class='material-symbols-outlined'>code</span></button>
                    </div>
                    <div class='header-actions'>
                        <button class='header-btn' id='search-btn' title='Search (Ctrl+F)'><span class='material-symbols-outlined'>search</span></button>
                        <button class='header-btn' id='expand-all' title='Expand All (E)'><span class='material-symbols-outlined'>unfold_more</span></button>
                        <button class='header-btn' id='collapse-all' title='Collapse All (C)'><span class='material-symbols-outlined'>unfold_less</span></button>
                        <button class='header-btn' id='copy-json' title='Copy JSON (Ctrl+C)'><span class='material-symbols-outlined'>content_copy</span></button>
                        <button class='header-btn' id='export-json' title='Export JSON'><span class='material-symbols-outlined'>download</span></button>
                    </div>
                </div>

                <div class='path-bar' id='path-bar'>
                    <button class='path-nav-btn' id='path-back-btn' title='Go Back' disabled>
                        <span class='material-symbols-outlined'>arrow_back</span>
                    </button>
                    <button class='path-nav-btn' id='path-forward-btn' title='Go Forward' disabled>
                        <span class='material-symbols-outlined'>arrow_forward</span>
                    </button>
                    <div class='path-segments' id='path-segments'></div>
                </div>

                <div class='main-container' id='main-container'>
                    <div class='nav-panel' id='nav-panel'>
                        <div class='panel-header'><span class='material-symbols-outlined'>explore</span>Navigator</div>
                        <div class='panel-content'>
                            <div class='column-view' id='column-view'></div>
                            <div class='tree-view' id='tree-view'></div>
                            <div class='json-view' id='json-view'></div>
                        </div>
                    </div>
                    <div class='resizer' id='resizer-left'></div>
                    <div class='preview-panel' id='preview-panel'>
                        <div class='panel-header'>
                            <span class='material-symbols-outlined'>visibility</span>Preview
                        </div>
                        <div class='preview-content' id='preview-content'></div>
                    </div>
                </div>

                <div class='status-bar'><span id='status-text'>Ready</span><span>Arrows to navigate | Enter to select</span></div>
            </div>

            <div class='search-overlay' id='search-overlay'>
                <input type='text' id='search-input' class='search-input' placeholder='Search (fuzzy match)...'>
                <div class='search-results' id='search-results'></div>
            </div>

            <div class='context-menu' id='context-menu'>
                <div class='context-menu-item' data-action='copy-path'><span class='material-symbols-outlined'>near_me</span>Copy Path</div>
                <div class='context-menu-item' data-action='copy-value'><span class='material-symbols-outlined'>content_copy</span>Copy Value</div>
                <div class='context-menu-item' data-action='copy-object'><span class='material-symbols-outlined'>data_object</span>Copy Object JSON</div>
                <div class='context-menu-separator'></div>
                <div class='context-menu-item' data-action='export'><span class='material-symbols-outlined'>download</span>Export JSON</div>
                <div class='context-menu-separator'></div>
                <div class='context-menu-item' data-action='select'><span class='material-symbols-outlined'>check_circle</span>Select & Exit</div>
            </div>

            <div class='toast' id='toast'><span class='material-symbols-outlined'>check</span><span id='toast-text'>Copied!</span></div>

        <script>

            // █▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀█
            // █                                  js                                  █
            // █▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄█

            (function() {
                var RAW_JSON = {{JSON_DATA}};
                var INITIAL_VIEW = '{{VIEW_MODE}}';
                var ENTER_TO_SUBMIT = '{{SUBMIT_ON_ENTER}}';
                
                // override initial view to tree as default
                if (!INITIAL_VIEW) INITIAL_VIEW = 'tree';
                
                // ╔──────────────────────────────────────────────────╗ 
                // ║                   dom elements                   ║ 
                // ╚──────────────────────────────────────────────────╝ 

                const els = {
                    container: document.getElementById('main-container'),
                    appContent: document.getElementById('app-content'),
                    nav: document.getElementById('nav-panel'),
                    preview: document.getElementById('preview-panel'),
                    colView: document.getElementById('column-view'),
                    treeView: document.getElementById('tree-view'),
                    jsonView: document.getElementById('json-view'),
                    prevContent: document.getElementById('preview-content'),
                    pathBar: document.getElementById('path-bar'),
                    pathSegments: document.getElementById('path-segments'),
                    pathBackBtn: document.getElementById('path-back-btn'),
                    pathForwardBtn: document.getElementById('path-forward-btn'),
                    search: document.getElementById('search-overlay'),
                    sInput: document.getElementById('search-input'),
                    sResults: document.getElementById('search-results'),
                    ctxMenu: document.getElementById('context-menu'),
                    toast: document.getElementById('toast'),
                    toastText: document.getElementById('toast-text'),
                    loader: document.getElementById('loading-overlay'),
                };

                var state = {
                    view: INITIAL_VIEW,
                    path: '',
                    cols: [],
                    expanded: {},
                    flat: [],
                    sTimer: null,
                    sTerm: '',
                    ctxPath: '',
                    ready: false,
                    navWidth: 0,
                    pathInfo: {},
                    fileContent: {},
                    history: [],
                    historyIndex: -1,
                    currentAudio: null,
                    propsCollapsed: false,
                    filePreviewCollapsed: false
                };

                // ╔──────────────────────────────────────────────────╗ 
                // ║                 helper functions                 ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function getType(v) { 
                    if (v === null) return 'null'; 
                    if (typeof v === 'boolean') return 'boolean';
                    if (Array.isArray(v)) return 'array'; 
                    return typeof v; 
                }            
                
                function getIcon(t, v) { 
                    if (t === 'boolean') return v ? 'check_circle' : 'cancel';
                    if (t === 'string') {
                        if (isUrl(v)) return 'link';
                        if (isFilePath(v)) return 'folder_open';
                        if (isColor(v)) return 'palette';
                        if (isValidDateString(v)) return 'calendar_month';
                        return 'match_case';
                    }
                    return {object:'data_object', array:'data_array', number:'tag', null:'do_not_disturb_on'}[t] || 'circle'; 
                }    

                function getTypeColorClass(t, v) {
                    if (t === 'boolean') return v ? 'boolean-true' : 'boolean-false';
                    if (t === 'string') {
                        if (isUrl(v)) return 'url';
                        if (isFilePath(v)) return 'url';  // use same color as url
                        return 'string';
                    }
                    return t;
                }

                function getVal(path) {
                    if (!path || path === '$') return RAW_JSON;
                    let v = RAW_JSON;
                    for (let p of parsePath(path)) { if (v == null) return undefined; v = v[p]; }
                    return v;
                }
                
                function parsePath(p) {
                    if (!p || p === '$') return [];
                    let parts = [], r = /\[(\d+)\]|\.?([^.\[\]]+)/g, m;
                    while ((m = r.exec(p)) !== null) parts.push(m[1] !== undefined ? parseInt(m[1]) : m[2]);
                    return parts;
                }

                function escapeHtml(text) {
                    var div = document.createElement('div');
                    div.textContent = text;
                    return div.innerHTML;
                }

                function formatFileSize(bytes) {
                    if (bytes === 0) return '0 B';
                    var k = 1024, sizes = ['B', 'KB', 'MB', 'GB'];
                    var i = Math.floor(Math.log(bytes) / Math.log(k));
                    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
                }

                function formatAhkDate(ahkDate) {
                    if (!ahkDate || ahkDate.length < 8) return '';
                    var y = ahkDate.substring(0, 4), m = ahkDate.substring(4, 6), d = ahkDate.substring(6, 8);
                    var h = ahkDate.length >= 10 ? ahkDate.substring(8, 10) : '00';
                    var mi = ahkDate.length >= 12 ? ahkDate.substring(10, 12) : '00';
                    return ``${y}-${m}-${d} ${h}:${mi}``;
                }

                function formatTime(seconds) {
                    if (isNaN(seconds) || !isFinite(seconds)) return '0:00';
                    var mins = Math.floor(seconds / 60);
                    var secs = Math.floor(seconds % 60);
                    return mins + ':' + (secs < 10 ? '0' : '') + secs;
                }

                function getExtLang(ext) {
                    var map = {
                        js: 'javascript', ts: 'typescript', py: 'python', ps1: 'powershell',
                        sh: 'bash', bat: 'batch', cmd: 'batch', ahk: 'autohotkey', ah2: 'autohotkey',
                        json: 'json', xml: 'xml', html: 'html', htm: 'html', css: 'css',
                        sql: 'sql', yaml: 'yaml', yml: 'yaml', md: 'markdown', ini: 'ini',
                        csv: 'csv', tsv: 'csv', txt: 'plaintext', log: 'plaintext'
                    };
                    return map[ext] || 'plaintext';
                }

                function getMimeType(ext) {
                    var map = {
                        png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif',
                        webp: 'image/webp', svg: 'image/svg+xml', ico: 'image/x-icon', bmp: 'image/bmp',
                        mp3: 'audio/mpeg', wav: 'audio/wav', ogg: 'audio/ogg', m4a: 'audio/mp4',
                        mp4: 'video/mp4', webm: 'video/webm', pdf: 'application/pdf',
                        json: 'application/json', xml: 'application/xml', html: 'text/html',
                        css: 'text/css', js: 'text/javascript', txt: 'text/plain', csv: 'text/csv'
                    };
                    return map[ext.toLowerCase()] || 'application/octet-stream';
                }

                function getFileTypeCategory(ext) {
                    ext = ext.toLowerCase();
                    if (/^(png|jpg|jpeg|gif|webp|svg|ico|bmp)$/.test(ext)) return 'image';
                    if (/^(mp3|wav|ogg|m4a|flac|aac)$/.test(ext)) return 'audio';
                    if (/^(mp4|webm|avi|mov|mkv)$/.test(ext)) return 'video';
                    if (/^(pdf)$/.test(ext)) return 'document';
                    return 'file';
                }

                // ╔──────────────────────────────────────────────────╗ 
                // ║              color helper functions              ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function parseColor(colorStr) {
                    var c = colorStr.trim().toLowerCase();
                    var r = 0, g = 0, b = 0, a = 1;
                    
                    // hex colors
                    if (c.startsWith('#')) {
                        var hex = c.slice(1);
                        if (hex.length === 3) {
                            r = parseInt(hex[0] + hex[0], 16);
                            g = parseInt(hex[1] + hex[1], 16);
                            b = parseInt(hex[2] + hex[2], 16);
                        } else if (hex.length === 6) {
                            r = parseInt(hex.slice(0, 2), 16);
                            g = parseInt(hex.slice(2, 4), 16);
                            b = parseInt(hex.slice(4, 6), 16);
                        } else if (hex.length === 8) {
                            r = parseInt(hex.slice(0, 2), 16);
                            g = parseInt(hex.slice(2, 4), 16);
                            b = parseInt(hex.slice(4, 6), 16);
                            a = parseInt(hex.slice(6, 8), 16) / 255;
                        }
                    }
                    // rgb/rgba
                    else if (c.startsWith('rgb')) {
                        var match = c.match(/rgba?\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+))?\s*\)/);
                        if (match) {
                            r = parseInt(match[1]); g = parseInt(match[2]); b = parseInt(match[3]);
                            if (match[4]) a = parseFloat(match[4]);
                        }
                    }
                    // hsl/hsla
                    else if (c.startsWith('hsl')) {
                        var match = c.match(/hsla?\s*\(\s*(\d+)\s*,\s*(\d+)%\s*,\s*(\d+)%\s*(?:,\s*([\d.]+))?\s*\)/);
                        if (match) {
                            var h = parseInt(match[1]) / 360, s = parseInt(match[2]) / 100, l = parseInt(match[3]) / 100;
                            if (match[4]) a = parseFloat(match[4]);
                            var hueToRgb = function(p, q, t) {
                                if (t < 0) t += 1; if (t > 1) t -= 1;
                                if (t < 1/6) return p + (q - p) * 6 * t;
                                if (t < 1/2) return q;
                                if (t < 2/3) return p + (q - p) * (2/3 - t) * 6;
                                return p;
                            };
                            if (s === 0) { r = g = b = Math.round(l * 255); }
                            else {
                                var q = l < 0.5 ? l * (1 + s) : l + s - l * s;
                                var p = 2 * l - q;
                                r = Math.round(hueToRgb(p, q, h + 1/3) * 255);
                                g = Math.round(hueToRgb(p, q, h) * 255);
                                b = Math.round(hueToRgb(p, q, h - 1/3) * 255);
                            }
                        }
                    }
                    // named colors
                    else {
                        var namedColors = {
                            red: [255,0,0], green: [0,128,0], blue: [0,0,255], yellow: [255,255,0],
                            orange: [255,165,0], purple: [128,0,128], pink: [255,192,203],
                            black: [0,0,0], white: [255,255,255], gray: [128,128,128], grey: [128,128,128],
                            cyan: [0,255,255], magenta: [255,0,255], brown: [165,42,42],
                            navy: [0,0,128], teal: [0,128,128], olive: [128,128,0], maroon: [128,0,0],
                            aqua: [0,255,255], lime: [0,255,0], silver: [192,192,192], fuchsia: [255,0,255]
                        };
                        if (namedColors[c]) { r = namedColors[c][0]; g = namedColors[c][1]; b = namedColors[c][2]; }
                    }
                    
                    return { r: r, g: g, b: b, a: a };
                }

                function rgbToHex(r, g, b) {
                    return '#' + [r, g, b].map(function(x) { return x.toString(16).padStart(2, '0'); }).join('');
                }

                function rgbToHsl(r, g, b) {
                    r /= 255; g /= 255; b /= 255;
                    var max = Math.max(r, g, b), min = Math.min(r, g, b);
                    var h, s, l = (max + min) / 2;
                    if (max === min) { h = s = 0; }
                    else {
                        var d = max - min;
                        s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
                        switch (max) {
                            case r: h = ((g - b) / d + (g < b ? 6 : 0)) / 6; break;
                            case g: h = ((b - r) / d + 2) / 6; break;
                            case b: h = ((r - g) / d + 4) / 6; break;
                        }
                    }
                    return { h: Math.round(h * 360), s: Math.round(s * 100), l: Math.round(l * 100) };
                }

                function getLuminance(r, g, b) {
                    var a = [r, g, b].map(function(v) {
                        v /= 255;
                        return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
                    });
                    return a[0] * 0.2126 + a[1] * 0.7152 + a[2] * 0.0722;
                }

                function getContrastRatio(lum1, lum2) {
                    var lighter = Math.max(lum1, lum2);
                    var darker = Math.min(lum1, lum2);
                    return ((lighter + 0.05) / (darker + 0.05)).toFixed(2);
                }

                // ╔──────────────────────────────────────────────────╗ 
                // ║              value type detection                ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function looksLikeMarkdown(text) {
                    if (!text || typeof text !== 'string') return false;
                    if (text.length < 20) return false;  // too short to be meaningful markdown
                    
                    // must have newlines to be markdown (single line strings are rarely markdown)
                    if (text.indexOf('\n') === -1) return false;
                    
                    var lines = text.split('\n');
                    var mdIndicators = 0;
                    
                    for (var i = 0; i < Math.min(lines.length, 30); i++) {  // check first 30 lines
                        var line = lines[i].trim();
                        
                        // headers: # at start of line (not in middle of text)
                        if (/^#{1,6}\s+\S/.test(line)) mdIndicators += 2;
                        
                        // code blocks: ```` at start of line
                        if (/^````/.test(line)) mdIndicators += 3;
                        
                        // bullet lists: - or * at start followed by space and text
                        if (/^[-*]\s+\S/.test(line)) mdIndicators++;
                        
                        // numbered lists: 1. 2. etc at start
                        if (/^\d+\.\s+\S/.test(line)) mdIndicators++;
                        
                        // blockquotes: > at start
                        if (/^>\s/.test(line)) mdIndicators++;
                        
                        // horizontal rules: --- or *** or ___ alone on line
                        if (/^(-{3,}|\*{3,}|_{3,})$/.test(line)) mdIndicators++;
                        
                        // tables: | at start and end of line with content
                        if (/^\|.+\|$/.test(line)) mdIndicators += 2;
                        
                        // table separator: |---|---|
                        if (/^\|[\s:-]+\|/.test(line)) mdIndicators += 2;
                    }
                    
                    // check for inline markdown patterns (but require multiples)
                    var linkCount = (text.match(/\[.+?\]\(.+?\)/g) || []).length;
                    var boldCount = (text.match(/\*\*[^*]+\*\*/g) || []).length;
                    var codeCount = (text.match(/``[^``]+``/g) || []).length;
                    
                    mdIndicators += linkCount;
                    mdIndicators += boldCount;
                    mdIndicators += Math.floor(codeCount / 2);  // inline code is common in non-md too
                    
                    // require at least 3 indicators to consider it markdown
                    return mdIndicators >= 3;
                }

                function isUrl(text) {
                    if (!text || typeof text !== 'string') return false;
                    return /^https?:\/\//i.test(text.trim());
                }

                function isColor(text) {
                    if (!text || typeof text !== 'string') return false;
                    var t = text.trim().toLowerCase();
                    if (/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(t)) return true;
                    if (/^rgba?\s*\(/.test(t)) return true;
                    if (/^hsla?\s*\(/.test(t)) return true;
                    var named = ['red','green','blue','yellow','orange','purple','pink','black','white','gray','grey','cyan','magenta','brown','navy','teal','olive','maroon','aqua','lime','silver','fuchsia'];
                    return named.indexOf(t) > -1;
                }

                function isDateOnlyString(text) { return /^\d{4}-\d{2}-\d{2}$/.test(text); }

                function isValidDateString(text) {
                    if (!text || typeof text !== 'string') return false;
                    var t = text.trim();
                    if (/^\d{4}-\d{2}-\d{2}(T|\s)?\d{0,2}/.test(t)) { var d = new Date(t); return !isNaN(d.getTime()); }
                    if (/^\d{1,2}\/\d{1,2}\/\d{2,4}$/.test(t)) { var d = new Date(t); return !isNaN(d.getTime()); }
                    return false;
                }

                function isFilePath(text) {
                    if (!text || typeof text !== 'string') return false;
                    var t = text.trim();
                    if (/^[a-zA-Z]:\\/.test(t)) return true;
                    if (/^\\\\/.test(t)) return true;
                    if (/^\/[a-zA-Z0-9_]/.test(t) && t.indexOf('/') > -1) return true;
                    if (/\.[a-zA-Z0-9]{1,6}$/.test(t) && (t.indexOf('/') > -1 || t.indexOf('\\') > -1)) return true;
                    return false;
                }

                function isFileUrl(url) {
                    if (!url || typeof url !== 'string') return false;
                    return /\.(png|jpg|jpeg|gif|webp|svg|ico|bmp|mp3|wav|ogg|m4a|mp4|webm|pdf)$/i.test(url.trim());
                }

                function getFileExtFromUrl(url) {
                    var match = url.match(/\.([a-zA-Z0-9]{1,6})(?:\?|#|$)/);
                    return match ? match[1].toLowerCase() : '';
                }

                function getFileExtFromPath(path) {
                    var match = path.match(/\.([a-zA-Z0-9]{1,6})$/);
                    return match ? match[1].toLowerCase() : '';
                }

                async function checkPathExists(path) {
                    if (state.pathInfo[path] !== undefined) return state.pathInfo[path];
                    try {
                        var result = await window.chrome.webview.hostObjects.check_path_handler(path);
                        state.pathInfo[path] = result ? JSON.parse(result) : null;
                    } catch (e) { state.pathInfo[path] = null; }
                    return state.pathInfo[path];
                }

                async function readFileContent(path) {
                    if (state.fileContent[path] !== undefined) return state.fileContent[path];
                    try {
                        var result = await window.chrome.webview.hostObjects.read_file_handler(path);
                        state.fileContent[path] = result ? JSON.parse(result) : null;
                    } catch (e) { state.fileContent[path] = null; }
                    return state.fileContent[path];
                }

                // ╔──────────────────────────────────────────────────╗ 
                // ║          get detailed type for display           ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function getDetailedType(v, t) {
                    if (t === 'boolean') {
                        return 'boolean';
                    }
                    if (t === 'number') {
                        return Number.isInteger(v) ? 'integer' : 'float';
                    }
                    if (t === 'string') {
                        if (isUrl(v)) {
                            if (isFileUrl(v)) {
                                var ext = getFileExtFromUrl(v);
                                var cat = getFileTypeCategory(ext);
                                return 'string/uri/' + cat + '/' + ext;
                            }
                            return 'string/uri';
                        }
                        if (isFilePath(v)) {
                            var ext = getFileExtFromPath(v);
                            if (ext) {
                                var cat = getFileTypeCategory(ext);
                                return 'string/uri/' + cat + '/' + ext;
                            }
                            return 'string/uri';
                        }
                        if (isColor(v)) return 'string/color';
                        if (isValidDateString(v)) return 'string/datetime';
                        return 'string';
                    }
                    return t;
                }

                // ╔──────────────────────────────────────────────────╗ 
                // ║                 fuzzy search                     ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function multiWordMatch(text, pattern) {
                    if (!pattern || !text) return -1;
                    var lower_text = text.toLowerCase();
                    var words = pattern.toLowerCase().split(/\s+/).filter(function(w) { return w.length > 0; });
                    if (words.length === 0) return -1;
                    
                    var total_score = 0;
                    var all_found = true;
                    
                    for (var i = 0; i < words.length; i++) {
                        var word = words[i];
                        var idx = lower_text.indexOf(word);
                        
                        if (idx === -1) {
                            all_found = false;
                            break;
                        }
                        
                        var word_score = 100 - Math.min(idx, 50);
                        if (idx === 0 || /[\s_.\-\/\\\[\]:@]/.test(text[idx - 1])) word_score += 50;
                        word_score += word.length * 2;
                        total_score += word_score;
                    }
                    
                    // if not all words found as-is, try matching individual characters in sequence
                    if (!all_found) {
                        var combined_pattern = words.join('');
                        var char_idx = 0;
                        var seq_score = 0;
                        for (var c = 0; c < lower_text.length && char_idx < combined_pattern.length; c++) {
                            if (lower_text[c] === combined_pattern[char_idx]) {
                                char_idx++;
                                seq_score += 1;
                            }
                        }
                        if (char_idx === combined_pattern.length) {
                            return seq_score;
                        }
                        return -1;
                    }
                    
                    return total_score;
                }

                function highlightFuzzy(text, pattern) {
                    if (!pattern || !text) return escapeHtml(String(text));
                    text = String(text);
                    var lower_text = text.toLowerCase();
                    var words = pattern.toLowerCase().split(/\s+/).filter(function(w) { return w.length > 0; });
                    if (words.length === 0) return escapeHtml(text);
                    
                    var ranges = [];
                    
                    // find all occurrences of each word
                    for (var w = 0; w < words.length; w++) {
                        var word = words[w];
                        var start_idx = 0;
                        while (true) {
                            var idx = lower_text.indexOf(word, start_idx);
                            if (idx === -1) break;
                            ranges.push({start: idx, end: idx + word.length});
                            start_idx = idx + 1;
                        }
                    }
                    
                    // also try to match the full pattern as substrings within words
                    // e.g., "website" should match "web" in "webhook" and "site" in "site"
                    var full_pattern = words.join('');
                    var pattern_idx = 0;
                    var current_range = null;
                    
                    for (var i = 0; i < lower_text.length && pattern_idx < full_pattern.length; i++) {
                        if (lower_text[i] === full_pattern[pattern_idx]) {
                            if (!current_range) {
                                current_range = {start: i, end: i + 1};
                            } else {
                                current_range.end = i + 1;
                            }
                            pattern_idx++;
                        } else if (current_range) {
                            ranges.push(current_range);
                            current_range = null;
                        }
                    }
                    if (current_range) ranges.push(current_range);
                    
                    if (ranges.length === 0) return escapeHtml(text);
                    
                    // sort and merge overlapping ranges
                    ranges.sort(function(a, b) { return a.start - b.start; });
                    var merged = [ranges[0]];
                    for (var i = 1; i < ranges.length; i++) {
                        var last = merged[merged.length - 1], curr = ranges[i];
                        if (curr.start <= last.end) { 
                            last.end = Math.max(last.end, curr.end); 
                        } else { 
                            merged.push(curr); 
                        }
                    }
                    
                    var result = '', pos = 0;
                    for (var i = 0; i < merged.length; i++) {
                        var range = merged[i];
                        if (pos < range.start) result += escapeHtml(text.substring(pos, range.start));
                        result += '<span class="highlight">' + escapeHtml(text.substring(range.start, range.end)) + '</span>';
                        pos = range.end;
                    }
                    if (pos < text.length) result += escapeHtml(text.substring(pos));
                    return result;
                }
                
                // ╔──────────────────────────────────────────────────╗ 
                // ║                 render functions                 ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function render() {
                    if (state.view === 'column') renderColumns();
                    else if (state.view === 'tree') renderTree();
                    else renderJsonView();
                    updatePreview();
                    updatePath();
                    updateStatus();
                }

                function renderColumns() {
                    els.colView.innerHTML = '';
                    let renderCol = (data, pPath, idx) => {
                        let col = document.createElement('div'); col.className = 'column';
                        let items = document.createElement('div'); items.className = 'column-items';
                        let keys = Array.isArray(data) ? data.map((_,i)=>i) : Object.keys(data);
                        
                        keys.forEach(k => {
                            let v = data[k], t = getType(v);
                            let path = Array.isArray(data) ? (pPath==='$' ? ``[${k}]`` : ``${pPath}[${k}]``) : (pPath==='$' ? k : ``${pPath}.${k}``);
                            let isSelected = (state.path === path);
                            
                            let el = document.createElement('div');
                            el.className = 'column-item' + (isSelected ? ' selected' : '');
                            el.dataset.path = path;
                            
                            let displayVal = '';
                            if (t === 'object' || t === 'array') {
                                displayVal = Array.isArray(v) ? v.length + ' items' : Object.keys(v).length + ' keys';
                            } else if (t === 'string') {
                                displayVal = '"' + (v.length > 30 ? v.substring(0, 30) + '...' : v) + '"';
                            } else { displayVal = String(v); }
                            
                            let colorClass = getTypeColorClass(t, v);
                            el.innerHTML = ``
                                <span class='material-symbols-outlined item-icon ${colorClass}'>${getIcon(t, v)}</span>
                                    <div class='item-content'>
                                        <span class='item-key'>${Array.isArray(data)?``[${k}]``:k}</span>
                                        <span style='color:var(--text-muted);margin:0 4px'>:</span>
                                        <span class='item-meta ${colorClass}'>${escapeHtml(displayVal)}</span>
                                    </div>
                                    ${t==='object'||t==='array' ? ``<span class='material-symbols-outlined item-chevron'>chevron_right</span>`` : ''}
                            ``;
                            el.onclick = () => navigate(path);
                            items.appendChild(el);
                        });
                        col.appendChild(items); els.colView.appendChild(col);
                        
                        if (state.cols[idx]) {
                            let nextVal = getVal(state.cols[idx].path);
                            if (typeof nextVal === 'object' && nextVal !== null) {
                                renderCol(nextVal, state.cols[idx].path, idx+1);
                            }
                        }
                    };
                    renderCol(RAW_JSON, '$', 0);
                    setTimeout(() => els.colView.scrollLeft = els.colView.scrollWidth, 0);
                }

                function renderTree() {
                    els.treeView.innerHTML = '';
                    let renderNode = (data, pPath, container, depth) => {
                        let keys = Array.isArray(data) ? data.map((_,i)=>i) : Object.keys(data);
                        keys.forEach(k => {
                            let v = data[k], t = getType(v);
                            let path = Array.isArray(data) ? (pPath==='$' ? ``[${k}]`` : ``${pPath}[${k}]``) : (pPath==='$' ? k : ``${pPath}.${k}``);
                            let hasKids = t === 'object' || t === 'array';
                            let expanded = state.expanded[path];
                            
                            let node = document.createElement('div');
                            let row = document.createElement('div');
                            row.className = 'node-row' + (state.path === path ? ' selected' : '');
                            row.dataset.path = path;
                            
                            let valDisplay = '';
                            if (hasKids) { valDisplay = Array.isArray(v) ? v.length + ' items' : Object.keys(v).length + ' keys'; }
                            else if (t === 'string') { valDisplay = '"' + (v.length > 50 ? v.substring(0, 50) + '...' : v) + '"'; }
                            else { valDisplay = String(v); }
                            
                            let colorClass = getTypeColorClass(t, v);
                            row.innerHTML = ``<span class='material-symbols-outlined expand-icon ${hasKids?(expanded?'expanded':''):'leaf'}'>arrow_right</span>
                                <span class='material-symbols-outlined item-icon ${colorClass}' style='font-size:16px'>${getIcon(t, v)}</span>
                                <span class='node-key'>${Array.isArray(data)?``[${k}]``:k}</span>
                                <span style='color:var(--text-muted);margin:0 4px'>:</span>
                                <span class='node-value ${colorClass}'>${escapeHtml(valDisplay)}</span>``;
                            
                            row.onclick = (e) => {
                                if (hasKids && (e.target.classList.contains('expand-icon') || e.detail===2)) {
                                    if (expanded) delete state.expanded[path]; else state.expanded[path] = true;
                                    renderTree();
                                }
                                selectItem(path);
                            };
                            
                            node.appendChild(row);
                            if (hasKids && expanded) {
                                let kids = document.createElement('div');
                                kids.className = 'node-children expanded';
                                kids.dataset.depth = depth % 8; // cycle through 8 colors
                                renderNode(v, path, kids, depth + 1);
                                node.appendChild(kids);
                            }
                            container.appendChild(node);
                        });
                    };
                    renderNode(RAW_JSON, '$', els.treeView, 0);
                    setTimeout(() => { let sel = els.treeView.querySelector('.selected'); if (sel) sel.scrollIntoView({block:'nearest'}); }, 0);
                }

                function renderJsonView() {
                    if (!els.jsonView.innerHTML) {
                        els.jsonView.innerHTML = ``<pre class='language-json'><code>${escapeHtml(JSON.stringify(RAW_JSON,null,2))}</code></pre>``;
                        Prism.highlightAllUnder(els.jsonView);
                    }
                }

                function createRawPreview(value, typeClass) {
                    var wrapper = document.createElement('div');
                    wrapper.className = 'preview-raw-wrapper';
                    
                    var raw = document.createElement('div');
                    raw.className = 'preview-raw ' + typeClass;
                    raw.textContent = String(value);
                    raw.onclick = function() { copyText(String(value)); };
                    wrapper.appendChild(raw);
                    
                    var copyBtn = document.createElement('button');
                    copyBtn.className = 'preview-raw-copy-btn';
                    copyBtn.innerHTML = ``<span class='material-symbols-outlined' style='font-size:12px'>content_copy</span>Copy``;
                    copyBtn.onclick = function(e) { 
                        e.stopPropagation();
                        copyText(String(value)); 
                    };
                    wrapper.appendChild(copyBtn);
                    
                    return wrapper;
                }

                // ╔──────────────────────────────────────────────────╗ 
                // ║          properties table in preview             ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function createPropertiesTable(props) {
                    var section = document.createElement('div');
                    section.className = 'preview-properties-section';
                    
                    // check if collapsed from state
                    if (state.propsCollapsed) section.classList.add('collapsed');
                    
                    // toggle arrow with label
                    var toggle = document.createElement('div');
                    toggle.className = 'preview-properties-toggle';
                    toggle.innerHTML = ``<span class='material-symbols-outlined'>expand_more</span>Properties``;
                    toggle.onclick = function() {
                        state.propsCollapsed = !state.propsCollapsed;
                        section.classList.toggle('collapsed', state.propsCollapsed);
                    };
                    section.appendChild(toggle);
                    
                    // table
                    var table = document.createElement('div');
                    table.className = 'preview-properties-table';
                    
                    props.forEach(function(prop) {
                        var row = document.createElement('div');
                        row.className = 'preview-prop-row';
                        row.innerHTML = ``
                            <div class='preview-prop-label'>${escapeHtml(prop.label)}</div>
                            <div class='preview-prop-value' title='${escapeHtml(prop.value)}'>${escapeHtml(prop.value)}</div>
                        ``;
                        row.querySelector('.preview-prop-value').onclick = function() { copyText(prop.value); };
                        table.appendChild(row);
                    });
                    
                    section.appendChild(table);
                    return section;
                }

                // ╔──────────────────────────────────────────────────╗ 
                // ║             special preview renders              ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function showUrlPreview(url, detailedType) {
                    // properties first
                    var props = [
                        {label: 'path', value: state.path || '$'},
                        {label: 'type', value: detailedType}
                    ];
                    
                    try {
                        var urlObj = new URL(url);
                        props.push({label: 'href', value: urlObj.href});
                        props.push({label: 'origin', value: urlObj.origin});
                        props.push({label: 'protocol', value: urlObj.protocol});
                        props.push({label: 'hostname', value: urlObj.hostname});
                        props.push({label: 'pathname', value: urlObj.pathname || '/'});
                        if (urlObj.search) {
                            props.push({label: 'search', value: urlObj.search});
                        }
                        if (isFileUrl(url)) {
                            var ext = getFileExtFromUrl(url);
                            props.push({label: 'mimeType', value: getMimeType(ext)});
                        }
                    } catch(e) {}
                    
                    els.prevContent.appendChild(createPropertiesTable(props));
                    els.prevContent.appendChild(createRawPreview(url, 'string'));
                    
                    // preview section
                    var c = document.createElement('div'); c.className = 'preview-url';
                    
                    // add embed preview
                    var embed = document.createElement('div'); embed.className = 'preview-url-embed';
                    
                    if (/\.(png|jpg|jpeg|gif|webp|svg)$/i.test(url)) {
                        var img = document.createElement('img');
                        img.src = url;
                        img.onerror = function() { 
                            embed.innerHTML = '<div class="preview-url-embed-error"><span class="material-symbols-outlined">broken_image</span><span>Failed to load image</span></div>'; 
                        };
                        embed.appendChild(img);
                        
                        img.onload = function() {
                            var info = document.createElement('div');
                            info.className = 'preview-url-embed-info';
                            info.textContent = img.naturalWidth + ' x ' + img.naturalHeight;
                            c.appendChild(info);
                        };
                    } else {
                        var placeholder = document.createElement('div'); placeholder.className = 'preview-url-embed-placeholder';
                        placeholder.innerHTML = ``
                            <span class='material-symbols-outlined' style='font-size:2rem'>language</span>
                            <span style='font-weight:500'>Web Preview</span>
                            <span style='font-size:0.8rem;text-align:center;max-width:300px'>Most websites block embedding due to security policies. Click "Open in Browser" to view the page.</span>
                        ``;
                        embed.appendChild(placeholder);
                    }
                    
                    c.appendChild(embed);
                    
                    // actions
                    var actions = document.createElement('div'); actions.className = 'preview-url-actions';
                    var openBtn = document.createElement('button'); openBtn.className = 'preview-url-btn';
                    openBtn.innerHTML = ``<span class='material-symbols-outlined' style='font-size:16px'>open_in_new</span>Open in Browser``;
                    openBtn.onclick = function() { try { window.chrome.webview.hostObjects.open_url_handler(url); } catch(e) {} };
                    actions.appendChild(openBtn);
                    
                    var copyBtn = document.createElement('button'); copyBtn.className = 'preview-url-btn';
                    copyBtn.innerHTML = ``<span class='material-symbols-outlined' style='font-size:16px'>content_copy</span>Copy URL``;
                    copyBtn.onclick = function() { copyText(url); };
                    actions.appendChild(copyBtn);
                    c.appendChild(actions);
                    
                    els.prevContent.appendChild(c);
                }

                function showColorPreview(color, detailedType) {
                    var parsed = parseColor(color);
                    var hsl = rgbToHsl(parsed.r, parsed.g, parsed.b);
                    var hex = rgbToHex(parsed.r, parsed.g, parsed.b);
                    var lum = getLuminance(parsed.r, parsed.g, parsed.b);
                    var textColor = lum > 0.5 ? '#000000' : '#ffffff';
                    var contrastLabel = lum > 0.5 ? 'light' : 'dark';
                    
                    // properties first
                    var props = [
                        {label: 'path', value: state.path || '$'},
                        {label: 'type', value: detailedType},
                        {label: 'hex', value: hex},
                        {label: 'rgb', value: ``rgb(${parsed.r}, ${parsed.g}, ${parsed.b})``},
                        {label: 'hsl', value: ``hsl(${hsl.h}, ${hsl.s}%, ${hsl.l}%)``},
                        {label: 'luminosity', value: lum.toFixed(4)},
                        {label: 'contrastRatio', value: contrastLabel}
                    ];
                    
                    els.prevContent.appendChild(createPropertiesTable(props));
                    els.prevContent.appendChild(createRawPreview(color, 'string'));
                    
                    // preview
                    var s = document.createElement('div'); 
                    s.className = 'preview-color'; 
                    s.style.backgroundColor = color;
                    s.style.color = textColor;
                    s.textContent = color;
                    els.prevContent.appendChild(s);
                }

                function showDatePreview(orig, detailedType) {
                    var dateOnly = isDateOnlyString(orig), date;
                    if (dateOnly) { var p = orig.split('-'); date = new Date(parseInt(p[0]), parseInt(p[1]) - 1, parseInt(p[2])); }
                    else { date = new Date(orig); }
                    
                    if (isNaN(date.getTime())) { 
                        var pre = document.createElement('div'); pre.className = 'preview-raw'; pre.textContent = '"' + orig + '"'; 
                        els.prevContent.appendChild(pre); 
                        return; 
                    }
                    
                    // properties first
                    var props = [
                        {label: 'path', value: state.path || '$'},
                        {label: 'type', value: detailedType},
                        {label: 'rfc3339', value: date.toISOString()},
                        {label: 'unix', value: Math.floor(date.getTime() / 1000).toString()},
                        {label: 'unix ms', value: date.getTime().toString()},
                        {label: 'date', value: date.toLocaleDateString('en-US', {month:'long', day:'numeric', year:'numeric'})}
                    ];
                    
                    els.prevContent.appendChild(createPropertiesTable(props));
                    els.prevContent.appendChild(createRawPreview(orig, 'string'));
                    
                    // preview - main date display
                    var c = document.createElement('div'); c.className = 'preview-date';
                    var main = document.createElement('div'); main.className = 'preview-date-main'; 
                    main.textContent = date.toLocaleDateString('en-US', {weekday:'short', month:'short', day:'numeric', year:'numeric'});
                    if (!dateOnly) {
                        main.textContent += ', ' + date.toLocaleTimeString('en-US');
                    }
                    c.appendChild(main);
                    
                    // calendar view
                    var calendar = document.createElement('div'); calendar.className = 'preview-date-calendar';
                    
                    var calHeader = document.createElement('div'); calHeader.className = 'preview-date-calendar-header';
                    ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'].forEach(function(day) {
                        var span = document.createElement('span'); span.textContent = day;
                        calHeader.appendChild(span);
                    });
                    calendar.appendChild(calHeader);
                    
                    var calBody = document.createElement('div'); calBody.className = 'preview-date-calendar-body';
                    
                    var year = date.getFullYear(), month = date.getMonth(), targetDay = date.getDate();
                    var firstDay = new Date(year, month, 1);
                    var lastDay = new Date(year, month + 1, 0);
                    var startDayOfWeek = (firstDay.getDay() + 6) % 7;
                    var daysInMonth = lastDay.getDate();
                    
                    var prevMonthLastDay = new Date(year, month, 0).getDate();
                    for (var i = startDayOfWeek - 1; i >= 0; i--) {
                        var dayEl = document.createElement('div'); dayEl.className = 'preview-date-calendar-day other-month';
                        dayEl.textContent = prevMonthLastDay - i;
                        calBody.appendChild(dayEl);
                    }
                    
                    for (var d = 1; d <= daysInMonth; d++) {
                        var dayEl = document.createElement('div'); dayEl.className = 'preview-date-calendar-day';
                        if (d === targetDay) {
                            dayEl.classList.add('selected');
                            var span = document.createElement('span');
                            span.textContent = d;
                            dayEl.appendChild(span);
                        } else {
                            dayEl.textContent = d;
                        }
                        calBody.appendChild(dayEl);
                    }
                    
                    var totalCells = startDayOfWeek + daysInMonth;
                    var remainingCells = (7 - (totalCells % 7)) % 7;
                    for (var i = 1; i <= remainingCells; i++) {
                        var dayEl = document.createElement('div'); dayEl.className = 'preview-date-calendar-day other-month';
                        dayEl.textContent = i;
                        calBody.appendChild(dayEl);
                    }
                    
                    calendar.appendChild(calBody);
                    c.appendChild(calendar);
                    
                    els.prevContent.appendChild(c);
                }

                async function showPathPreview(pathStr, detailedType) {
                    var info = await checkPathExists(pathStr);
                    var ext = getFileExtFromPath(pathStr);
                    
                    // properties first
                    var props = [
                        {label: 'path', value: state.path || '$'},
                        {label: 'type', value: detailedType},
                        {label: 'href', value: pathStr},
                        {label: 'origin', value: 'file://'},
                        {label: 'protocol', value: 'file:'},
                        {label: 'hostname', value: 'localhost'},
                        {label: 'pathname', value: pathStr}
                    ];
                    if (ext) {
                        props.push({label: 'mimeType', value: getMimeType(ext)});
                    }
                    
                    els.prevContent.appendChild(createPropertiesTable(props));
                    els.prevContent.appendChild(createRawPreview(pathStr, 'string'));
                    
                    // preview section
                    var c = document.createElement('div'); c.className = 'preview-path';
                    
                    // action buttons
                    var actions = document.createElement('div'); actions.className = 'preview-path-actions';
                    
                    if (info && info.exists) {
                        if (info.isDir) {
                            var openFolderBtn = document.createElement('button'); openFolderBtn.className = 'preview-path-btn';
                            openFolderBtn.innerHTML = ``<span class='material-symbols-outlined' style='font-size:16px'>folder_open</span>Open Folder``;
                            openFolderBtn.onclick = function() { try { window.chrome.webview.hostObjects.open_path_handler(pathStr); } catch(e) {} };
                            actions.appendChild(openFolderBtn);
                        } else {
                            var openFileBtn = document.createElement('button'); openFileBtn.className = 'preview-path-btn';
                            openFileBtn.innerHTML = ``<span class='material-symbols-outlined' style='font-size:16px'>open_in_new</span>Open File``;
                            openFileBtn.onclick = function() { try { window.chrome.webview.hostObjects.open_path_handler(pathStr); } catch(e) {} };
                            actions.appendChild(openFileBtn);
                            
                            var openContainingBtn = document.createElement('button'); openContainingBtn.className = 'preview-path-btn';
                            openContainingBtn.innerHTML = ``<span class='material-symbols-outlined' style='font-size:16px'>folder_open</span>Open Folder``;
                            openContainingBtn.onclick = function() {
                                try {
                                    var folder = pathStr.substring(0, Math.max(pathStr.lastIndexOf('\\'), pathStr.lastIndexOf('/')));
                                    window.chrome.webview.hostObjects.open_path_handler(folder);
                                } catch(e) {}
                            };
                            actions.appendChild(openContainingBtn);
                        }
                    }

                    var copyPathBtn = document.createElement('button'); copyPathBtn.className = 'preview-path-btn';
                    copyPathBtn.innerHTML = ``<span class='material-symbols-outlined' style='font-size:16px'>content_copy</span>Copy Path``;
                    copyPathBtn.onclick = function() { copyText(pathStr); };
                    actions.appendChild(copyPathBtn);
                    
                    c.appendChild(actions);
                    els.prevContent.appendChild(c);
                    
                    // file preview if exists and not a directory
                    if (info && info.exists && !info.isDir) {
                        var content = await readFileContent(pathStr);
                        
                        if (content) {
                            // create collapsible wrapper
                            var filePreviewSection = document.createElement('div');
                            filePreviewSection.className = 'preview-section-collapsible';
                            if (state.filePreviewCollapsed) filePreviewSection.classList.add('collapsed');
                            
                            // create toggle header
                            var fileToggle = document.createElement('div');
                            fileToggle.className = 'preview-properties-toggle';
                            fileToggle.innerHTML = ``<span class='material-symbols-outlined'>expand_more</span>File Preview``;
                            fileToggle.onclick = function() {
                                state.filePreviewCollapsed = !state.filePreviewCollapsed;
                                filePreviewSection.classList.toggle('collapsed', state.filePreviewCollapsed);
                            };
                            filePreviewSection.appendChild(fileToggle);
                            
                            // create content container
                            var fileContentWrapper = document.createElement('div');
                            fileContentWrapper.className = 'preview-section-content';
                            
                            if (content.type === 'image') {
                                var imgContainer = document.createElement('div');
                                imgContainer.style.textAlign = 'center';
                                imgContainer.style.marginTop = '0.5rem';
                                var img = document.createElement('img');
                                img.className = 'file-preview-image';
                                img.src = 'data:' + content.mime + ';base64,' + content.data;
                                imgContainer.appendChild(img);
                                fileContentWrapper.appendChild(imgContainer);
                            } else if (content.type === 'audio') {
                                var audioContainer = document.createElement('div');
                                audioContainer.style.marginTop = '0.5rem';
                                createAudioPlayer(audioContainer, content, pathStr);
                                fileContentWrapper.appendChild(audioContainer);
                            } else if (content.type === 'text') {
                                var wrapper = document.createElement('div');
                                wrapper.style.marginTop = '0.5rem';
                                
                                // check if it's a markdown file - render as markdown instead of code
                                if (content.ext === 'md' || content.ext === 'markdown') {
                                    var md = document.createElement('div');
                                    md.className = 'markdown-body';
                                    try {
                                        md.innerHTML = marked.parse(content.content);
                                        Prism.highlightAllUnder(md);
                                    } catch (e) {
                                        md.textContent = content.content;
                                    }
                                    wrapper.appendChild(md);
                                    
                                    // add copy button
                                    var copyBtnWrapper = document.createElement('div');
                                    copyBtnWrapper.style.marginTop = '0.5rem';
                                    var copyBtn = document.createElement('button');
                                    copyBtn.className = 'preview-path-btn';
                                    copyBtn.innerHTML = ``<span class='material-symbols-outlined' style='font-size:16px'>content_copy</span>Copy Raw``;
                                    copyBtn.onclick = function() { copyText(content.content); };
                                    copyBtnWrapper.appendChild(copyBtn);
                                    wrapper.appendChild(copyBtnWrapper);
                                    
                                    fileContentWrapper.appendChild(wrapper);
                                } else {
                                    // regular code file
                                    wrapper.className = 'preview-code-wrapper';
                                    
                                    var codeDiv = document.createElement('div');
                                    codeDiv.className = 'file-preview-code';
                                    var pre = document.createElement('pre');
                                    var code = document.createElement('code');
                                    code.className = 'language-' + getExtLang(content.ext);
                                    code.textContent = content.content;
                                    pre.appendChild(code);
                                    codeDiv.appendChild(pre);
                                    wrapper.appendChild(codeDiv);
                                    
                                    var copyBtn = document.createElement('button');
                                    copyBtn.className = 'preview-code-copy-btn';
                                    copyBtn.innerHTML = ``<span class='material-symbols-outlined' style='font-size:14px'>content_copy</span>Copy``;
                                    copyBtn.onclick = function() { copyText(content.content); };
                                    wrapper.appendChild(copyBtn);
                                    
                                    fileContentWrapper.appendChild(wrapper);
                                    
                                    // highlight after appending to DOM
                                    filePreviewSection.appendChild(fileContentWrapper);
                                    els.prevContent.appendChild(filePreviewSection);
                                    Prism.highlightElement(code);
                                    return; // early return since we already appended
                                }
                                
                                filePreviewSection.appendChild(fileContentWrapper);
                                els.prevContent.appendChild(filePreviewSection);
                                return;
                            } else if (content.type === 'error') {
                                var errDiv = document.createElement('div');
                                errDiv.className = 'file-preview-error';
                                errDiv.style.marginTop = '0.5rem';
                                errDiv.textContent = content.message;
                                fileContentWrapper.appendChild(errDiv);
                            }
                            
                            filePreviewSection.appendChild(fileContentWrapper);
                            els.prevContent.appendChild(filePreviewSection);
                        }
                    }
                }      

                // ╔──────────────────────────────────────────────────╗ 
                // ║                   audio player                   ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function createAudioPlayer(container, content, pathStr) {
                    var filename = pathStr.split(/[/\\]/).pop() || 'Audio File';
                    var ext = filename.split('.').pop().toUpperCase();
                    
                    var playerContainer = document.createElement('div');
                    playerContainer.className = 'audio-player-container';
                    
                    var playerId = 'audio-' + Date.now() + '-' + Math.random().toString(36).substr(2, 9);
                    
                    // create audio element first
                    var audio = document.createElement('audio');
                    audio.preload = 'auto';
                    
                    playerContainer.innerHTML = ``
                        <div class='audio-player-header'>
                            <div class='audio-player-icon'>
                                <span class='material-symbols-outlined'>music_note</span>
                            </div>
                            <div class='audio-player-info'>
                                <div class='audio-player-title'>${escapeHtml(filename)}</div>
                                <div class='audio-player-subtitle'>${ext} Audio</div>
                            </div>
                        </div>
                        <div class='audio-player-controls'>
                            <button class='audio-play-btn' data-player='${playerId}'>
                                <span class='material-symbols-outlined'>play_arrow</span>
                            </button>
                            <div class='audio-progress-container'>
                                <div class='audio-progress-bar' data-player='${playerId}'>
                                    <div class='audio-progress-fill' data-player='${playerId}'></div>
                                </div>
                                <div class='audio-time'>
                                    <span class='audio-current-time' data-player='${playerId}'>0:00</span>
                                    <span class='audio-duration' data-player='${playerId}'>--:--</span>
                                </div>
                            </div>
                            <div class='audio-volume-container'>
                                <button class='audio-volume-btn' data-player='${playerId}'>
                                    <span class='material-symbols-outlined'>volume_up</span>
                                </button>
                                <div class='audio-volume-slider' data-player='${playerId}'>
                                    <div class='audio-volume-fill' data-player='${playerId}'></div>
                                </div>
                            </div>
                        </div>
                    ``;
                    
                    audio.dataset.player = playerId;
                    playerContainer.appendChild(audio);
                    container.appendChild(playerContainer);
                    
                    // get elements using data attributes
                    var playBtn = playerContainer.querySelector('.audio-play-btn[data-player="' + playerId + '"]');
                    var progressBar = playerContainer.querySelector('.audio-progress-bar[data-player="' + playerId + '"]');
                    var progressFill = playerContainer.querySelector('.audio-progress-fill[data-player="' + playerId + '"]');
                    var currentTimeEl = playerContainer.querySelector('.audio-current-time[data-player="' + playerId + '"]');
                    var durationEl = playerContainer.querySelector('.audio-duration[data-player="' + playerId + '"]');
                    var volumeBtn = playerContainer.querySelector('.audio-volume-btn[data-player="' + playerId + '"]');
                    var volumeSlider = playerContainer.querySelector('.audio-volume-slider[data-player="' + playerId + '"]');
                    var volumeFill = playerContainer.querySelector('.audio-volume-fill[data-player="' + playerId + '"]');
                    
                    var isPlaying = false;
                    var isMuted = false;
                    
                    function updateDuration() {
                        if (audio.duration && isFinite(audio.duration)) {
                            durationEl.textContent = formatTime(audio.duration);
                        }
                    }
                    
                    audio.addEventListener('loadedmetadata', updateDuration);
                    audio.addEventListener('durationchange', updateDuration);
                    audio.addEventListener('canplay', updateDuration);
                    audio.addEventListener('canplaythrough', updateDuration);
                    
                    audio.addEventListener('timeupdate', function() {
                        if (audio.duration && isFinite(audio.duration)) {
                            var progress = (audio.currentTime / audio.duration) * 100;
                            progressFill.style.width = progress + '%';
                            currentTimeEl.textContent = formatTime(audio.currentTime);
                        }
                    });
                    
                    audio.addEventListener('ended', function() {
                        isPlaying = false;
                        playBtn.innerHTML = '<span class="material-symbols-outlined">play_arrow</span>';
                        progressFill.style.width = '0%';
                        currentTimeEl.textContent = '0:00';
                    });
                    
                    audio.addEventListener('error', function(e) {
                        console.error('Audio error:', e);
                        playBtn.innerHTML = '<span class="material-symbols-outlined">error</span>';
                    });
                    
                    playBtn.addEventListener('click', function() {
                        if (!isPlaying) {
                            if (state.currentAudio && state.currentAudio !== audio) {
                                state.currentAudio.pause();
                                state.currentAudio.currentTime = 0;
                            }
                            state.currentAudio = audio;
                            
                            audio.play().then(function() {
                                isPlaying = true;
                                playBtn.innerHTML = '<span class="material-symbols-outlined">pause</span>';
                            }).catch(function(err) {
                                console.error('Play error:', err);
                            });
                        } else {
                            audio.pause();
                            isPlaying = false;
                            playBtn.innerHTML = '<span class="material-symbols-outlined">play_arrow</span>';
                        }
                    });
                    
                    progressBar.addEventListener('click', function(e) {
                        if (!audio.duration || !isFinite(audio.duration)) return;
                        var rect = progressBar.getBoundingClientRect();
                        var percent = (e.clientX - rect.left) / rect.width;
                        audio.currentTime = percent * audio.duration;
                    });
                    
                    volumeBtn.addEventListener('click', function() {
                        isMuted = !isMuted;
                        audio.muted = isMuted;
                        volumeBtn.innerHTML = isMuted ? '<span class="material-symbols-outlined">volume_off</span>' : '<span class="material-symbols-outlined">volume_up</span>';
                        volumeFill.style.width = isMuted ? '0%' : (audio.volume * 100) + '%';
                    });
                    
                    volumeSlider.addEventListener('click', function(e) {
                        var rect = volumeSlider.getBoundingClientRect();
                        var percent = (e.clientX - rect.left) / rect.width;
                        audio.volume = Math.max(0, Math.min(1, percent));
                        volumeFill.style.width = (audio.volume * 100) + '%';
                        if (audio.volume > 0) {
                            isMuted = false;
                            audio.muted = false;
                            volumeBtn.innerHTML = '<span class="material-symbols-outlined">volume_up</span>';
                        }
                    });
                    
                    // set source after all listeners are attached
                    console.log('Audio mime:', content.mime);
                    console.log('Audio data length:', content.data ? content.data.length : 'no data');
                    console.log('Audio src preview:', ('data:' + content.mime + ';base64,' + content.data).substring(0, 100));
                    audio.src = 'data:' + content.mime + ';base64,' + content.data;
                }

                // ╔──────────────────────────────────────────────────╗ 
                // ║                     markdown                     ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function showMarkdownPreview(text) {               
                    var md = document.createElement('div'); 
                    md.className = 'markdown-body';
                    
                    try {
                        md.innerHTML = marked.parse(text);
                    } catch (e) {
                        md.textContent = text;  
                    }
                    
                    els.prevContent.appendChild(md);
                    Prism.highlightAllUnder(md);
                }

                // ╔──────────────────────────────────────────────────╗ 
                // ║          properties display in preview           ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function addPropItem(container, label, value) {
                    var prop = document.createElement('div'); prop.className = 'preview-prop-item';
                    prop.innerHTML = ``<span class='preview-prop-label'>${escapeHtml(label)}:</span><span class='preview-prop-value' title='${escapeHtml(value)}'>${escapeHtml(value)}</span>``;
                    prop.querySelector('.preview-prop-value').onclick = function() { copyText(value); };
                    container.appendChild(prop);
                }

                function renderPropertiesInPreview(v, t, path) {
                    var wrapper = document.createElement('div'); 
                    wrapper.className = 'preview-properties-wrapper';
                    
                    // use state variable instead of localStorage
                    if (state.propsCollapsed) wrapper.classList.add('collapsed');
                    
                    var header = document.createElement('div');
                    header.className = 'preview-properties-header';
                    header.innerHTML = ``
                        <div class='preview-properties-title'>
                            <span class='material-symbols-outlined'>expand_more</span>
                            Properties
                        </div>
                        <span class='preview-properties-toggle'>${state.propsCollapsed ? 'Show' : 'Hide'}</span>
                    ``;
                    header.onclick = function() {
                        state.propsCollapsed = !state.propsCollapsed;
                        wrapper.classList.toggle('collapsed', state.propsCollapsed);
                        header.querySelector('.preview-properties-toggle').textContent = state.propsCollapsed ? 'Show' : 'Hide';
                    };
                    wrapper.appendChild(header);
                    
                    var propsDiv = document.createElement('div'); 
                    propsDiv.className = 'preview-properties';
                    
                    var detailedType = getDetailedType(v, t);
                    
                    // path property
                    addPropItem(propsDiv, 'Path', path || '$');
                    
                    // type property
                    addPropItem(propsDiv, 'Type', detailedType);
                    
                    // length/keys count
                    if (t === 'string') {
                        addPropItem(propsDiv, 'Length', v.length + ' chars');
                    } else if (t === 'array') {
                        addPropItem(propsDiv, 'Items', v.length.toString());
                    } else if (t === 'object') {
                        addPropItem(propsDiv, 'Keys', Object.keys(v).length.toString());
                    }
                    
                    wrapper.appendChild(propsDiv);
                    
                    // return both wrapper and propsDiv so we can add more properties later
                    wrapper.propsDiv = propsDiv;
                    return wrapper;
                }

                // ╔──────────────────────────────────────────────────╗ 
                // ║                  update preview                  ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function updatePreview() {
                    if (state.view === 'json') return;
                    
                    // stop any playing audio when changing preview
                    if (state.currentAudio) {
                        state.currentAudio.pause();
                        state.currentAudio.currentTime = 0;
                        state.currentAudio = null;
                    }
                    
                    let v = getVal(state.path), t = getType(v);
                    els.prevContent.innerHTML = '';
                    
                    if (v === undefined) { 
                        els.prevContent.innerHTML = '<div style="color:var(--text-muted);text-align:center;margin-top:2rem">Select a node</div>'; 
                        return; 
                    }
                    
                    // get detailed type for display
                    var detailedType = getDetailedType(v, t);
                    var colorClass = getTypeColorClass(t, v);
                    
                    // special types handle their own properties
                    if (t === 'string') {
                        if (isUrl(v)) { showUrlPreview(v, detailedType); return; }
                        if (isColor(v)) { showColorPreview(v, detailedType); return; }
                        if (isValidDateString(v)) { showDatePreview(v, detailedType); return; }
                        if (isFilePath(v)) { showPathPreview(v, detailedType); return; }
                        if (looksLikeMarkdown(v)) { 
                            var props = [
                                {label: 'path', value: state.path || '$'},
                                {label: 'type', value: 'string/markdown'},
                                {label: 'length', value: v.length + ' chars'}
                            ];
                            els.prevContent.appendChild(createPropertiesTable(props));
                            showMarkdownPreview(v); 
                            return; 
                        }
                    }
                    
                    // properties first for default types
                    var props = [
                        {label: 'path', value: state.path || '$'},
                        {label: 'type', value: detailedType}
                    ];
                    
                    if (t === 'string') {
                        props.push({label: 'length', value: v.length + ' chars'});
                    } else if (t === 'array') {
                        props.push({label: 'items', value: v.length.toString()});
                    } else if (t === 'object') {
                        props.push({label: 'keys', value: Object.keys(v).length.toString()});
                    }
                    
                    els.prevContent.appendChild(createPropertiesTable(props));
                    
                    // preview section
                    if (t === 'object' || t === 'array') {
                        var wrapper = document.createElement('div');
                        wrapper.className = 'preview-code-wrapper';
                        
                        var pre = document.createElement('pre'); 
                        pre.className = 'language-json';
                        pre.innerHTML = ``<code>${escapeHtml(JSON.stringify(v, null, 2))}</code>``;
                        wrapper.appendChild(pre);
                        
                        var copyBtn = document.createElement('button');
                        copyBtn.className = 'preview-code-copy-btn';
                        copyBtn.innerHTML = ``<span class='material-symbols-outlined' style='font-size:14px'>content_copy</span>Copy``;
                        copyBtn.onclick = function() { copyText(JSON.stringify(v, null, 2)); };
                        wrapper.appendChild(copyBtn);
                        
                        els.prevContent.appendChild(wrapper);
                        Prism.highlightElement(pre.firstChild);
                    } else if (t === 'boolean') {
                        els.prevContent.appendChild(createRawPreview(v ? 'true' : 'false', colorClass));
                    } else if (t === 'null') {
                        els.prevContent.appendChild(createRawPreview('null', 'null'));
                    } else if (t === 'number') {
                        els.prevContent.appendChild(createRawPreview(v, 'number'));
                    } else {
                        // string
                        els.prevContent.appendChild(createRawPreview(v, 'string'));
                    }
                }

                // ╔──────────────────────────────────────────────────╗ 
                // ║             update path bar (above)              ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function updatePath() {
                    els.pathSegments.innerHTML = '';
                    let parts = parsePath(state.path), cur = '';
                    
                    // update history buttons
                    els.pathBackBtn.disabled = state.historyIndex <= 0;
                    els.pathForwardBtn.disabled = state.historyIndex >= state.history.length - 1;
                    
                    let addSeg = (txt, p, icon, isLast) => {
                        let s = document.createElement('span'); 
                        s.className = 'path-segment' + (isLast ? ' active' : '');
                        s.innerHTML = ``<span class='material-symbols-outlined'>${icon}</span>${escapeHtml(txt)}``;
                        s.onclick = () => navigate(p);
                        els.pathSegments.appendChild(s);
                    };
                    
                    // root segment
                    let rootType = getType(RAW_JSON);
                    let rootIcon = rootType === 'array' ? 'data_array' : 'data_object';
                    addSeg('root', '$', rootIcon, parts.length === 0);
                    
                    parts.forEach((p, i) => {
                        // add separator
                        let sep = document.createElement('span'); 
                        sep.className = 'material-symbols-outlined path-separator'; 
                        sep.textContent = 'chevron_right';
                        els.pathSegments.appendChild(sep);
                        
                        // build current path
                        let parentVal = cur === '' ? RAW_JSON : getVal(cur);
                        cur = Array.isArray(parentVal) || cur === '' 
                            ? (cur === '' ? (typeof p === 'number' ? ``[${p}]`` : p) : ``${cur}[${p}]``) 
                            : ``${cur}.${p}``;
                        
                        // get icon for this segment
                        let val = getVal(cur);
                        let valType = getType(val);
                        let segIcon = getIcon(valType);
                        let isLast = i === parts.length - 1;
                        
                        addSeg(typeof p === 'number' ? ``${p}`` : p, cur, segIcon, isLast);
                    });
                    
                    // scroll to end
                    setTimeout(() => els.pathSegments.scrollLeft = els.pathSegments.scrollWidth, 0);
                }
                
                function updateStatus() { document.getElementById('status-text').textContent = ``${state.flat.length} nodes | ${state.path || '$'}``; }

                // ╔──────────────────────────────────────────────────╗ 
                // ║                   navigation                     ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function selectItem(path) {
                    state.path = path || '';
                    updatePreview(); updatePath(); updateStatus();
                    if (state.view === 'column') renderColumns();
                    else if (state.view === 'tree') renderTree();
                }

                function navigate(path, addToHistory = true) {
                    // add to history
                    if (addToHistory) {
                        // remove forward history if we're navigating from middle
                        if (state.historyIndex < state.history.length - 1) {
                            state.history = state.history.slice(0, state.historyIndex + 1);
                        }
                        state.history.push(path || '');
                        state.historyIndex = state.history.length - 1;
                    }
                    
                    state.path = path || '';
                    state.cols = [];
                    if (path) {
                        let parts = parsePath(path), cp = '$', walker = RAW_JSON;
                        for (let p of parts) {
                            let nextP = Array.isArray(walker) ? (cp==='$'?``[${p}]``:``${cp}[${p}]``) : (cp==='$'?p:``${cp}.${p}``);
                            state.cols.push({path: nextP});
                            walker = walker[p]; cp = nextP;
                        }
                    }
                    if (state.view === 'tree') {
                        let parts = parsePath(path), cp = '$';
                        parts.forEach((p, i) => {
                            if (i < parts.length - 1) {
                                let v = getVal(cp);
                                let nextP = Array.isArray(v) ? (cp==='$'?``[${p}]``:``${cp}[${p}]``) : (cp==='$'?p:``${cp}.${p}``);
                                state.expanded[nextP] = true; cp = nextP;
                            }
                        });
                    }
                    render();
                }

                function navigateBack() {
                    if (state.historyIndex > 0) {
                        state.historyIndex--;
                        navigate(state.history[state.historyIndex], false);
                    }
                }

                function navigateForward() {
                    if (state.historyIndex < state.history.length - 1) {
                        state.historyIndex++;
                        navigate(state.history[state.historyIndex], false);
                    }
                }

                function switchView(mode) {
                    state.view = mode;
                    document.querySelectorAll('.view-btn').forEach(b => b.classList.toggle('active', b.dataset.view === mode));
                    els.colView.classList.toggle('active', mode === 'column');
                    els.treeView.classList.toggle('active', mode === 'tree');
                    els.jsonView.classList.toggle('active', mode === 'json');
                    els.container.classList.toggle('container-json-mode', mode === 'json');
                    
                    // ensure a node is selected for navigation
                    if (!state.path && mode !== 'json') {
                        let firstKey = Array.isArray(RAW_JSON) ? 0 : Object.keys(RAW_JSON)[0];
                        if (firstKey !== undefined) {
                            state.path = Array.isArray(RAW_JSON) ? ``[${firstKey}]`` : firstKey;
                        }
                    }
                    
                    render();
                }

                // ╔──────────────────────────────────────────────────╗ 
                // ║                     search                       ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function buildFlat() {
                    state.flat = [];
                    let walk = (v, p, k) => {
                        let t = getType(v);
                        let displayValue;
                        
                        if (t === 'object') {
                            displayValue = Object.keys(v).length + ' keys';
                        } else if (t === 'array') {
                            displayValue = v.length + ' items';
                        } else if (t === 'string') {
                            displayValue = v;
                        } else if (t === 'boolean') {
                            displayValue = v ? 'true' : 'false';
                        } else if (t === 'null') {
                            displayValue = 'null';
                        } else {
                            displayValue = String(v);
                        }
                        
                        state.flat.push({path: p, key: k, value: v, type: t, displayValue: displayValue});
                        
                        if (t === 'object') Object.keys(v).forEach(ky => walk(v[ky], p ? ``${p}.${ky}`` : ky, ky));
                        if (t === 'array') v.forEach((it, i) => walk(it, ``${p}[${i}]``, ``[${i}]``));
                    };
                    walk(RAW_JSON, '', '$');
                }

                function doSearch(term) {
                    state.sTerm = term.trim(); 
                    els.sResults.innerHTML = '';
                    if (!state.sTerm) return;
                    
                    var results = [];
                    for (var i = 0; i < state.flat.length; i++) {
                        var n = state.flat[i];
                        var combined = [n.key || '', n.displayValue || '', n.path || ''].join(' ');
                        var best_score = Math.max(
                            multiWordMatch(combined, state.sTerm), 
                            multiWordMatch(n.key, state.sTerm), 
                            multiWordMatch(String(n.displayValue), state.sTerm), 
                            multiWordMatch(n.path, state.sTerm) );
                        if (best_score >= 0) results.push({node: n, score: best_score});
                    }
                    results.sort(function(a, b) { return b.score - a.score; });
                    
                    // add results count header
                    var countHeader = document.createElement('div');
                    countHeader.className = 'search-results-count';
                    countHeader.textContent = results.length + ' results';
                    els.sResults.appendChild(countHeader);
                    
                    results.slice(0, 50).forEach((r, i) => {
                        var n = r.node, el = document.createElement('div');
                        el.className = 'search-result-item' + (i === 0 ? ' selected' : '');
                        var valStr = String(n.displayValue); 
                        if (valStr.length > 60) valStr = valStr.substring(0, 60) + '...';
                        
                        // format path as breadcrumb
                        var breadcrumb = formatPathAsBreadcrumb(n.path);
                        var colorClass = getTypeColorClass(n.type, n.value);
                        
                        el.innerHTML = ``
                            <div class='search-result-header'>
                                <span class='material-symbols-outlined item-icon ${colorClass}'>${getIcon(n.type, n.value)}</span>
                                <span class='search-result-key'>${highlightFuzzy(n.key, state.sTerm)}</span>
                            </div>
                            <div class='search-result-path'>${breadcrumb}</div>
                            <div class='search-result-value ${colorClass}'>${highlightFuzzy(valStr, state.sTerm)}</div>``;
                        el.onclick = () => { navigate(n.path); els.search.classList.remove('active'); };
                        els.sResults.appendChild(el);
                    });
                }

                function formatPathAsBreadcrumb(path) {
                    if (!path) return 'root';
                    var parts = parsePath(path);
                    var segments = ['root'];
                    parts.forEach(p => {
                        segments.push(typeof p === 'number' ? ``[${p}]`` : p);
                    });
                    return segments.map(s => ``<span class='breadcrumb-segment'>${escapeHtml(s)}</span>``).join('<span class="breadcrumb-sep"> › </span>');
                }

                // ╔──────────────────────────────────────────────────╗ 
                // ║                keyboard navigation               ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function getColumnSiblings() {
                    let parts = parsePath(state.path);
                    if (parts.length === 0) return { items: Object.keys(RAW_JSON), parent: RAW_JSON, parentPath: '$' };
                    let parentParts = parts.slice(0, -1), parentPath = '', walker = RAW_JSON;
                    for (let i = 0; i < parentParts.length; i++) {
                        let p = parentParts[i];
                        parentPath = Array.isArray(walker) ? (parentPath === '' ? ``[${p}]`` : ``${parentPath}[${p}]``) : (parentPath === '' ? p : ``${parentPath}.${p}``);
                        walker = walker[p];
                    }
                    let parent = parentParts.length === 0 ? RAW_JSON : getVal(parentPath);
                    return { items: Array.isArray(parent) ? parent.map((_, i) => i) : Object.keys(parent), parent: parent, parentPath: parentPath || '$' };
                }

                function handleNav(key) {
                    if (state.view === 'json') return;
                    
                    if (state.view === 'column') {
                        let parts = parsePath(state.path);
                        let currentVal = getVal(state.path);
                        
                        if (key === 'ArrowDown' || key === 'ArrowUp') {
                            // get siblings at current level
                            let parentPath = '';
                            let parent = RAW_JSON;
                            
                            if (parts.length > 0) {
                                // build parent path
                                let walker = RAW_JSON;
                                for (let i = 0; i < parts.length - 1; i++) {
                                    let p = parts[i];
                                    parentPath = Array.isArray(walker) 
                                        ? (parentPath === '' ? ``[${p}]`` : ``${parentPath}[${p}]``) 
                                        : (parentPath === '' ? p : ``${parentPath}.${p}``);
                                    walker = walker[p];
                                }
                                parent = parts.length === 1 ? RAW_JSON : getVal(parentPath);
                            }
                            
                            let items = Array.isArray(parent) ? parent.map((_, i) => i) : Object.keys(parent);
                            let currentKey = parts[parts.length - 1];
                            let currentIdx = -1;
                            
                            // find current index in items array
                            for (let i = 0; i < items.length; i++) {
                                if (items[i] === currentKey || String(items[i]) === String(currentKey)) {
                                    currentIdx = i;
                                    break;
                                }
                            }
                            
                            if (key === 'ArrowDown' && currentIdx < items.length - 1) {
                                let nextKey = items[currentIdx + 1];
                                let newPath = Array.isArray(parent) 
                                    ? (parentPath === '' ? ``[${nextKey}]`` : ``${parentPath}[${nextKey}]``) 
                                    : (parentPath === '' ? nextKey : ``${parentPath}.${nextKey}``);
                                selectItem(newPath);
                            } else if (key === 'ArrowUp' && currentIdx > 0) {
                                let prevKey = items[currentIdx - 1];
                                let newPath = Array.isArray(parent) 
                                    ? (parentPath === '' ? ``[${prevKey}]`` : ``${parentPath}[${prevKey}]``) 
                                    : (parentPath === '' ? prevKey : ``${parentPath}.${prevKey}``);
                                selectItem(newPath);
                            }
                        } else if (key === 'ArrowLeft') {
                            // only go up ONE level, never jump to root
                            if (parts.length > 1) {
                                // build path to parent (remove last part)
                                let walker = RAW_JSON;
                                let parentPath = '';
                                for (let i = 0; i < parts.length - 1; i++) {
                                    let p = parts[i];
                                    parentPath = Array.isArray(walker) 
                                        ? (parentPath === '' ? ``[${p}]`` : ``${parentPath}[${p}]``) 
                                        : (parentPath === '' ? p : ``${parentPath}.${p}``);
                                    walker = walker[p];
                                }
                                navigate(parentPath);
                            } else if (parts.length === 1) {
                                // at first level, go to root
                                navigate('');
                            }
                            // if parts.length === 0, already at root - do nothing
                        } else if (key === 'ArrowRight') {
                            // drill into object/array
                            if (currentVal && typeof currentVal === 'object' && currentVal !== null) {
                                let keys = Array.isArray(currentVal) ? currentVal.map((_, i) => i) : Object.keys(currentVal);
                                if (keys.length > 0) {
                                    let firstKey = keys[0];
                                    let newPath = Array.isArray(currentVal) 
                                        ? ``${state.path}[${firstKey}]`` 
                                        : (state.path === '' ? firstKey : ``${state.path}.${firstKey}``);
                                    navigate(newPath);
                                }
                            }
                        }
                    } else if (state.view === 'tree') {
                        let vis = Array.from(els.treeView.querySelectorAll('.node-row'));
                        let curr = els.treeView.querySelector('.node-row.selected');
                        let idx = vis.indexOf(curr);
                        
                        if (key === 'ArrowDown' && idx < vis.length - 1) {
                            selectItem(vis[idx + 1].dataset.path);
                        } else if (key === 'ArrowUp' && idx > 0) {
                            selectItem(vis[idx - 1].dataset.path);
                        } else if (key === 'ArrowRight' && curr) {
                            let p = curr.dataset.path, v = getVal(p);
                            if (v && typeof v === 'object' && !state.expanded[p]) { 
                                state.expanded[p] = true; 
                                renderTree(); 
                            }
                        } else if (key === 'ArrowLeft' && curr) {
                            let p = curr.dataset.path;
                            if (state.expanded[p]) { 
                                delete state.expanded[p]; 
                                renderTree(); 
                            } else { 
                                let parts = parsePath(p); 
                                if (parts.length > 1) {
                                    // go up one level
                                    let walker = RAW_JSON;
                                    let parentPath = '';
                                    for (let i = 0; i < parts.length - 1; i++) {
                                        let pt = parts[i];
                                        parentPath = Array.isArray(walker) 
                                            ? (parentPath === '' ? ``[${pt}]`` : ``${parentPath}[${pt}]``) 
                                            : (parentPath === '' ? pt : ``${parentPath}.${pt}``);
                                        walker = walker[pt];
                                    }
                                    selectItem(parentPath);
                                } else if (parts.length === 1) {
                                    selectItem('');
                                }
                            }
                        }
                    }
                }

                // ╔──────────────────────────────────────────────────╗ 
                // ║                panel resizing                    ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function initResize() {
                    let bar = document.getElementById('resizer-left');
                    let panel = els.nav;
                    bar.onmousedown = (e) => {
                        let startX = e.clientX, startW = panel.offsetWidth;
                        bar.classList.add('active');
                        let onMove = (ev) => {
                            let delta = ev.clientX - startX;
                            let w = startW + delta;
                            if (w > 150 && w < window.innerWidth - 200) {
                                panel.style.width = w + 'px';
                                state.navWidth = w;
                            }
                        };
                        let onUp = () => { 
                            bar.classList.remove('active'); 
                            window.removeEventListener('mousemove', onMove); 
                            window.removeEventListener('mouseup', onUp);
                            if (state.view === 'column') renderColumns();
                        };
                        window.addEventListener('mousemove', onMove); 
                        window.addEventListener('mouseup', onUp);
                    };
                }

                // ╔──────────────────────────────────────────────────╗ 
                // ║                  copy & export                   ║ 
                // ╚──────────────────────────────────────────────────╝ 

                window.copyText = (txt) => { try { window.chrome.webview.hostObjects.copy_handler(txt); } catch(e) {} showToast('Copied!'); };
                function showToast(msg) { els.toastText.textContent = msg; els.toast.classList.add('show'); setTimeout(() => els.toast.classList.remove('show'), 2000); }

                async function exportJson(path) {
                    let v = path ? getVal(path) : RAW_JSON;
                    if (v === undefined) v = RAW_JSON;
                    let jsonStr = JSON.stringify(v, null, 2);
                    try {
                        let savedPath = await window.chrome.webview.hostObjects.save_file_handler(jsonStr, 'export.json');
                        if (savedPath) showToast('Saved!');
                    } catch (e) {
                        let blob = new Blob([jsonStr], { type: 'application/json' });
                        let url = URL.createObjectURL(blob);
                        let a = document.createElement('a'); a.href = url; a.download = 'export.json';
                        document.body.appendChild(a); a.click(); document.body.removeChild(a);
                        URL.revokeObjectURL(url);
                        showToast('Exported!');
                    }
                }

                // ╔──────────────────────────────────────────────────╗ 
                // ║                 global listeners                 ║ 
                // ╚──────────────────────────────────────────────────╝ 

                document.getElementById('expand-all').onclick = () => {
                    state.flat.forEach(n => { if (n.type==='object'||n.type==='array') state.expanded[n.path]=true; });
                    if(state.view==='tree') renderTree();
                };
                document.getElementById('collapse-all').onclick = () => {
                    state.expanded = {};
                    if(state.view==='tree') renderTree();
                };
                document.getElementById('copy-json').onclick = () => copyText(JSON.stringify(RAW_JSON, null, 2));
                document.getElementById('export-json').onclick = () => exportJson(state.path);
                els.pathBackBtn.onclick = () => navigateBack();
                els.pathForwardBtn.onclick = () => navigateForward();

                // ╔──────────────────────────────────────────────────╗ 
                // ║                   context menu                   ║ 
                // ╚──────────────────────────────────────────────────╝ 

                window.oncontextmenu = (e) => {
                    let el = e.target.closest('[data-path]');
                    if (el) {
                        e.preventDefault();
                        state.ctxPath = el.dataset.path;
                        els.ctxMenu.style.left = e.clientX + 'px';
                        els.ctxMenu.style.top = e.clientY + 'px';
                        els.ctxMenu.classList.add('active');
                    }
                };
                window.onclick = (e) => {
                    if (!e.target.closest('.context-menu')) els.ctxMenu.classList.remove('active');
                };
                document.querySelectorAll('.context-menu-item').forEach(el => {
                    el.onclick = () => {
                        let act = el.dataset.action, val = getVal(state.ctxPath);
                        if (act==='copy-path') copyText(state.ctxPath);
                        if (act==='copy-value') copyText(typeof val==='object'?JSON.stringify(val):String(val));
                        if (act==='copy-object') copyText(JSON.stringify(val,null,2));
                        if (act==='export') exportJson(state.ctxPath);
                        if (act==='select') try{ window.chrome.webview.hostObjects.select_handler(state.ctxPath); }catch(e){}
                        els.ctxMenu.classList.remove('active');
                    };
                });

                // ╔──────────────────────────────────────────────────╗ 
                // ║               loading & init logic               ║ 
                // ╚──────────────────────────────────────────────────╝ 

                function hideLoader() {
                    document.body.classList.remove('loading');
                    els.appContent.classList.add('ready');
                    els.loader.classList.add('hidden');
                }

                function checkLibrariesReady() {
                    if (typeof marked !== 'undefined' && typeof Prism !== 'undefined') {
                        state.ready = true;
                        initApp();
                        setTimeout(hideLoader, 100); // small delay to ensure DOM is painted
                    } else {
                        setTimeout(checkLibrariesReady, 100);
                    }
                }

                function initApp() {
                    buildFlat();
                    document.querySelectorAll('.view-btn').forEach(b => b.onclick = () => switchView(b.dataset.view));
                    document.getElementById('search-btn').onclick = () => { 
                        els.search.classList.add('active'); 
                        els.sInput.focus(); 
                    };
                    els.sInput.oninput = (e) => { 
                        clearTimeout(state.sTimer); 
                        state.sTimer = setTimeout(() => doSearch(e.target.value), 150); 
                    };
                    els.sInput.onkeydown = (e) => {
                        if (e.key === 'Escape') els.search.classList.remove('active');
                        if (e.key === 'Enter') { 
                            let sel = els.sResults.querySelector('.selected'); 
                            if (sel) sel.click(); 
                        }
                        if (['ArrowUp','ArrowDown'].includes(e.key)) {
                            e.preventDefault();
                            let all = Array.from(els.sResults.children), idx = all.findIndex(x=>x.classList.contains('selected'));
                            if (idx > -1) all[idx].classList.remove('selected');
                            let next = e.key==='ArrowDown' ? Math.min(idx+1, all.length-1) : Math.max(idx-1, 0);
                            if (all[next]) { 
                                all[next].classList.add('selected'); 
                                all[next].scrollIntoView({block:'nearest'}); 
                            }
                        }
                    };

                    document.onkeydown = (e) => {
                        if (els.search.classList.contains('active')) return;
                        if (e.ctrlKey && e.key === 'f') { 
                            e.preventDefault(); 
                            document.getElementById('search-btn').click(); 
                            return; 
                        }
                        
                        if (e.key === 'c' && !e.ctrlKey && !e.altKey) {
                            e.preventDefault();
                            document.getElementById('collapse-all').click();
                            return;
                        }

                        if (e.key === 'e' && !e.ctrlKey && !e.altKey) {
                            e.preventDefault();
                            document.getElementById('expand-all').click();
                            return;
                        }

                        if (e.key === 'Enter' && state.path && ENTER_TO_SUBMIT === '1') window.chrome.webview.hostObjects.select_handler(JSON.stringify({path: state.path, value: getVal(state.path)},null,2));
                        if (e.key === '1') switchView('tree');
                        if (e.key === '2') switchView('column');
                        if (e.key === '3') switchView('json');
                        if (['ArrowUp','ArrowDown','ArrowLeft','ArrowRight'].includes(e.key)) { 
                            e.preventDefault(); 
                            handleNav(e.key); 
                        }
                    };

                    initResize();
                    
                    var initialNavWidth = Math.max(550, Math.min(700, window.innerWidth * 0.5));
                    els.nav.style.width = initialNavWidth + 'px';
                    state.navWidth = initialNavWidth;
                    
                    // initialize history with root
                    state.history = [''];
                    state.historyIndex = 0;
                    
                    switchView(INITIAL_VIEW);
                    if (INITIAL_VIEW === 'tree') renderTree();
                    else if (INITIAL_VIEW === 'column') navigate(''); 
                    else renderJsonView();
                }

                // start checking for libraries
                checkLibrariesReady();

            })();
        </script>
        </body>
        </html>
    )"
}
