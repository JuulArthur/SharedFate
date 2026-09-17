class_name StoryChapter
extends Resource

# One chapter of narration for the story book: a title and the pages that are
# written onto the book, in order. Pages fill the left leaf, then the right,
# then the book turns to a fresh spread, so an even page count looks tidiest.
#
# Chapters are authored in code in `StoryLibrary` (the same way `ItemFactory`
# builds items) and identified by `id` so a level can ask for one by name and
# `StoryBook` can remember which have already been read.

@export var id: StringName = &""
@export var title: String = ""
@export_multiline var pages: Array[String] = []


static func make(chapter_id: StringName, chapter_title: String, chapter_pages: Array[String]) -> StoryChapter:
	var chapter := StoryChapter.new()
	chapter.id = chapter_id
	chapter.title = chapter_title
	chapter.pages = chapter_pages
	return chapter
