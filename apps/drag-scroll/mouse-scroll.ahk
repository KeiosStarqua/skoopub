; Drag to scroll - AutoHotkey v2 port of Mikhail V.'s mouse-scroll-v04.ahk
; Source: https://github.com/Mikhail22/drag-scroll--autohotkey
; Hold RIGHT Alt (RAlt) and move the mouse to scroll; release to stop.
; A press with no scrolling sends RAlt so the key is not swallowed.
#Requires AutoHotkey v2.0
#SingleInstance Force

; === User settings ===
swap := false      ; true reverses the scroll direction
horiz := true      ; true uses horizontal mouse movement as the input
k := 1             ; scroll speed coefficient (higher = faster)
; Lower k and higher S make scrolling slower; lower T makes it smoother
; (more frequent, smaller wheel steps instead of occasional bursts).

; === Internal settings ===
scrollsLimit := 5  ; max wheel notches sent per timer tick
S := 24            ; unit distance (higher = slower)
T := 15            ; scan frequency in ms (lower = smoother)

running := false
dyTotal := 0
scrollsTotal := 0
mxLast := 0
myLast := 0

SetTimer(Watch, T)

Watch() {
    global running, horiz, k, S, scrollsLimit, dyTotal, scrollsTotal, mxLast, myLast
    if (!running)
        return

    MouseGetPos(&mx, &my)
    if (horiz) {
        dy := k * (mx - mxLast)
        mxLast := mx
    } else {
        dy := k * (my - myLast)
        myLast := my
    }

    dyTotal += dy
    scrolls := Floor(dyTotal / S)
    dyTotal -= scrolls * S
    direction := (scrolls >= 0) ^ swap
    scrollsN := Abs(scrolls)
    scrollsTotal += scrollsN
    n := Min(scrollsN, scrollsLimit)
    if (n = 0)
        return

    if (direction = 1)
        Send("{WheelDown " n "}")
    else
        Send("{WheelUp " n "}")
}

; Without ~ the native RAlt is suppressed while held, so it cannot trigger
; menu/shortcut side effects during a scroll drag. If the press produced no
; scrolling, send RAlt so a plain press still behaves normally.
RAlt:: {
    global running, dyTotal, mxLast, myLast
    running := true
    dyTotal := 0
    MouseGetPos(&mxLast, &myLast)
}

RAlt up:: {
    global running, scrollsTotal
    running := false
    if (scrollsTotal = 0)
        Send("{RAlt}")
    scrollsTotal := 0
}
