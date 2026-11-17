local _ = require("gettext")
return {
    name = "classicscover",
    fullname = _("Classics Cover Generator"),
    description = _([[Generates a Classics-style cover for a book, entirely on the device.
Hold a book in the file browser and choose "Classics Cover".
Fetches the title and author from the book metadata, renders a random gradient
background with the Classics strip, and saves the result as the book's custom
cover. No server or network connection is needed.]]),
}
