local _ = require("gettext")
return {
    name = "penguincover",
    fullname = _("Classics Cover Generator"),
    description = _([[Generates a Classics-style cover for a book.
Hold a book in the file browser to find the "Generate Classics Cover" option.
Fetches title and author from book metadata, sends them to your cover server,
and saves the result as a custom cover for the book.]]),
}
