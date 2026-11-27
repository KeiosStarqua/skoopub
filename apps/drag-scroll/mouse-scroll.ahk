; Drag to scroll - AutoHotkey v2 port of Mikhail V.'s mouse-scroll-v04.ahk
; Source: https://github.com/Mikhail22/drag-scroll--autohotkey
; Hold the RIGHT mouse button and move the mouse to scroll; release to stop.
#Requires AutoHotkey v2.0
#SingleInstance Force

; === User settings ===
swap := false      ; true reverses the scroll direction
horiz := true      ; true uses horizontal mouse movement as the input
k := 2             ; scroll speed coefficient (higher = faster)

; === Internal settings ===
scrollsLimit := 15 ; max wheel notches sent per timer tick
S := 12            ; unit distance (higher = slower)
T := 30            ; scan frequency in ms

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

; Without ~ the native right-click is suppressed, so the context menu only
; appears when the drag produced no scrolling (matching the v1 behaviour).
RButton:: {
    global running, dyTotal, mxLast, myLast
    running := true
    dyTotal := 0
    MouseGetPos(&mxLast, &myLast)
}

RButton up:: {
    global running, scrollsTotal
    running := false
    if (scrollsTotal = 0)
        Send("{RButton}")
    scrollsTotal := 0
}
