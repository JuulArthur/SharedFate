class_name EmberInkEffect
extends RichTextEffect

## The 3D story book's ink: the dark-fantasy twin of the 2D `MagicInkEffect`.
## Wrap a RichTextLabel's body in [ember_ink]...[/ember_ink] and advance
## `reveal_head`: characters ahead of the head are hidden, the newest burn in
## white-hot and flicker, cool through ember red, and settle to near-black ink,
## as if the words were being seared into the page.
##
## The label redraws every frame while it holds a custom effect, so the caller
## only moves `reveal_head`.

var bbcode := "ember_ink"

# How many characters (fractional) have been written so far.
var reveal_head := 0.0
# How many characters behind the head are still cooling.
var trail := 14.0
# How far a fresh character jitters while it is still hot, in pixels.
var jitter_pixels := 1.2

var ink := Color(0.10, 0.06, 0.05, 1.0)
var ember := Color(0.78, 0.16, 0.06, 1.0)
var heat := Color(1.0, 0.80, 0.42, 1.0)


func _process_custom_fx(char_fx: CharFXTransform) -> bool:
	var age := (reveal_head - float(char_fx.relative_index)) / trail
	if age <= 0.0:
		char_fx.visible = false
		return true

	var t := clampf(age, 0.0, 1.0)
	# White heat for the first fifth, then ember, then ink; eased so the red
	# lingers a moment before the page swallows it.
	var color: Color
	if t < 0.2:
		color = heat.lerp(ember, t / 0.2)
	else:
		color = ember.lerp(ink, 1.0 - pow(1.0 - (t - 0.2) / 0.8, 2.0))
	color.a = clampf(age * 4.0, 0.0, 1.0)
	char_fx.color = color

	if t < 1.0:
		# Each glyph shivers on its own phase while it is hot.
		var phase := char_fx.elapsed_time * 31.0 + float(char_fx.relative_index) * 1.7
		var strength := (1.0 - t) * jitter_pixels
		char_fx.offset = Vector2(sin(phase) * strength, cos(phase * 1.3) * strength)
	return true
