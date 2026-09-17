class_name MagicInkEffect
extends RichTextEffect

# Writes text onto the page as if by an unseen quill. Wrap the body of a
# RichTextLabel in [magic_ink]...[/magic_ink] and advance `reveal_head` over
# time: characters ahead of the head are hidden, characters just behind it
# glow gold and drift down into place, and everything older settles to ink.
#
# The label redraws every frame while it holds a custom effect, so the caller
# only has to move `reveal_head`; nothing here needs to be ticked.

var bbcode := "magic_ink"

# How many characters (fractional) have been written so far.
var reveal_head := 0.0
# How many characters behind the head are still glowing.
var trail := 10.0
# How far a fresh character floats above its resting place before settling.
var rise_pixels := 6.0

var ink := Color(0.20, 0.14, 0.09, 1.0)
var glow := Color(1.0, 0.86, 0.45, 1.0)


func _process_custom_fx(char_fx: CharFXTransform) -> bool:
	var age := (reveal_head - float(char_fx.relative_index)) / trail
	if age <= 0.0:
		char_fx.visible = false
		return true

	var t := clampf(age, 0.0, 1.0)
	# Ease-out so the glow lingers a moment before darkening to ink.
	var settled := 1.0 - pow(1.0 - t, 2.0)
	char_fx.color = glow.lerp(ink, settled)
	char_fx.color.a = clampf(age * 3.0, 0.0, 1.0)
	char_fx.offset.y = -(1.0 - settled) * rise_pixels
	return true
