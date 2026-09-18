class_name StoryLibrary
extends RefCounted

# Every chapter of narration the game can show, built in code so the text lives
# next to the systems it describes and needs no editor plumbing to change.
#
# Ask for a chapter by id from a level's `_ready()`:
#   StoryBook.show_chapter_once(StoryLibrary.chapter(&"prologue"))
#
# To add a chapter: write a `_build_<name>()` returning a StoryChapter and
# register it in `chapter()`. Keep each page to roughly 40-70 words; the ink is
# written at about 38 characters a second, so that is a comfortable 8-12 seconds
# a page before the reader has to wait on it.

const PROLOGUE: StringName = &"prologue"
const CASTLE: StringName = &"castle"
const FOREST: StringName = &"forest"
const BLACK_WOODS: StringName = &"black_woods"


static func chapter(id: StringName) -> StoryChapter:
	match id:
		PROLOGUE:
			return _build_prologue()
		CASTLE:
			return _build_castle()
		FOREST:
			return _build_forest()
		BLACK_WOODS:
			return _build_black_woods()
	return null


# --- Chapters ----------------------------------------------------------------

# The opening: how a knight, a rogue and a mage ended up sharing one body, and
# why they have to work together. The three map onto the three reactions the
# player already has — the knight's shield arm is Block, the rogue's quick hands
# are Parry, the mage's fire is Ward and the spells — so later chapters can
# introduce each ability as one of the three waking up.
#
# Names come from `Soul`, so renaming a character there renames them here too.
static func _build_prologue() -> StoryChapter:
	var knight := Soul.KNIGHT_NAME
	var rogue := Soul.ROGUE_NAME
	var mage := Soul.MAGE_NAME
	return StoryChapter.make(PROLOGUE, "The Bound Three", [
		"Three strangers came to the ruin of Castle Vael on the same storm-black night, "
		+ "and not one of them knew the others were there.\n\n"
		+ "%s came for his oath. The Heartstone had been his order's to guard, " % knight
		+ "and his order was dead. He meant to carry it somewhere safe, or die in the trying.",

		"%s came for the price on it. A stone that old, in a castle that empty, was the " % rogue
		+ "easiest coin a thief would ever earn. The vault door was already unlocked when "
		+ "the knight's torch found the thief beside it.\n\n"
		+ "And %s came for the truth. The wards on the Heartstone were older than any " % mage
		+ "spell in the mage's books, and %s meant to read them before someone careless " % mage
		+ "broke them.",

		"Steel met dagger in the dark. The mage shouted for them both to stop, and neither "
		+ "listened.\n\n"
		+ "Three hands closed on the Heartstone in the same heartbeat.\n\n"
		+ "It did what it had been made to do. It bound.",

		"%s woke on the vault floor with the taste of a stranger's fear in his mouth " % knight
		+ "and a stranger's spell half-spoken on his tongue. He was alone. He was not alone.\n\n"
		+ "\"You,\" said a voice inside his skull, dry and unimpressed. \"You absolute clod "
		+ "of a knight.\"\n\n"
		+ "\"Please,\" said a second voice, quieter, \"nobody move until I understand what "
		+ "just happened.\"",

		"The Heartstone lay shattered at his feet. Its shards had scattered on the storm-wind "
		+ "into the black woods and the castle's forgotten halls, and every one of them still "
		+ "hummed with a fragment of the binding.\n\n"
		+ "Three souls. One body. A knight's shield arm, a rogue's quick hands, and a mage's "
		+ "half-remembered fire.",

		"Every shard they gather will loosen the knot a little. Until the last one is found, "
		+ "the Bound Three will have to learn to fight, to steal, to cast - and, hardest of "
		+ "all, to agree.\n\n"
		+ "Their story begins where it went wrong: at the foot of the ruin, with the wolves "
		+ "already howling in the trees.",
	])


# Short interlude for the castle. A placeholder to show the between-chapter
# flow; replace with the real chapter when the castle has its own story beat.
static func _build_castle() -> StoryChapter:
	return StoryChapter.make(CASTLE, "The Vault", [
		"Back to the halls where it happened. The wards on the walls still flicker with the "
		+ "Heartstone's colour, and %s goes very quiet whenever they pass one.\n\n" % Soul.MAGE_NAME
		+ "Something else has been moving in the castle since the night the stone broke. "
		+ "%s, for once, votes against going in." % Soul.ROGUE_NAME,
	])


# The Black Woods: the first hunt for a shard. Read when `scenes/black_woods.tscn`
# opens. The wolf packs and the pool it mentions are real features of that map
# (see tools/build_black_woods.gd), so keep them in step if the map changes.
static func _build_black_woods() -> StoryChapter:
	return StoryChapter.make(BLACK_WOODS, "The Black Woods", [
		"The trees close behind them before the ruin is out of sight, and the glow of "
		+ "the mage's ward thins to a candle-flame in the wet dark.\n\n"
		+ "The wolves have been waiting. Not hunting - waiting. %s counts eyes between " % Soul.ROGUE_NAME
		+ "the trunks, and stops counting at nine.",

		"Somewhere ahead lies a pool that should be black and is not. Something beneath "
		+ "the water hums the way the Heartstone used to hum, and all three of them "
		+ "hear it at once.\n\n"
		+ "\"The first shard,\" says %s. \"Do try not to bleed on it.\"" % Soul.MAGE_NAME,
	])


# Short interlude for the forest. Same placeholder status as the castle chapter.
static func _build_forest() -> StoryChapter:
	return StoryChapter.make(FOREST, "The Black Woods", [
		"The wind carried the shards into the woods, and the woods noticed.\n\n"
		+ "The wolves circling the tree-line are not hunting for meat. Whatever the "
		+ "Heartstone was guarding against, it has had three hundred years to get hungry.",
	])
