on run argv
    set targetURL to item 1 of argv
    set savedID to item 2 of argv
    if (count of argv) >= 3 then
        set hintList to items 3 thru -1 of argv
    else
        set hintList to {}
    end if
    tell application "Google Chrome"
        set bestWindow to missing value
        if savedID is not "" then
            try
                set bestWindow to window id (savedID as integer)
            end try
        end if
        if bestWindow is missing value and (count of hintList) > 0 then
            set bestScore to 0
            repeat with w in windows
                set score to 0
                repeat with t in tabs of w
                    set u to URL of t
                    repeat with h in hintList
                        if u contains h then
                            set score to score + 1
                            exit repeat
                        end if
                    end repeat
                end repeat
                if score > bestScore then
                    set bestScore to score
                    set bestWindow to w
                end if
            end repeat
        end if
        if bestWindow is missing value then return "none"
        make new tab at end of tabs of bestWindow with properties {URL:targetURL}
        set active tab index of bestWindow to (count of tabs of bestWindow)
        set index of bestWindow to 1
        activate
        return "ok " & (id of bestWindow)
    end tell
end run
