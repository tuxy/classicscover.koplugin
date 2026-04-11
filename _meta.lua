local _ = require("gettext")
return {
    name = "penguincover",
    fullname = _("Penguin Cover Generator"),
    description = _([[Generates a Penguin Classics-style cover for a book.
Hold a book in the file browser to find the "Generate Penguin Cover" option.
Fetches title and author from book metadata, sends them to your cover server,
and saves the result as a custom cover for the book.]]),
}