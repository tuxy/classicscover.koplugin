# Penguin Cover - Koreader Plugin 
## A KOReader plugin generate book cover directly from koreader and automatically replaced it. Tested on Kindle Paperwhite 12 Koreader 03.2026
-----
![[Untitled design (1).png]]
![[FileManager_2026-04-11_084959.png]]
## 📚 Penguin Cover Generator. How It Works
1. Make sure your device is connected to the internet
2. Long-press the book you want to book cover changed.
3. Tap **“Penguin Cover”**
4. Choose a background image  (make sure you already copied the image to /koreader/backgrounds)
5. Confirm or edit the book title and author
6. Tap **Generate**
7. Wait until you see the notification: _“Cover image applied”_
8. Done 🎉
## Installation
-----
1. Download the Zip Below
2. Extract and copy the penguincover. Koplugin folder to your device's plugins/ directory
3. Restart KOReader and go to **Menu -> Tools -> Penguin Cover Generator** to change the settings.
   
## Technical Details:
This plugin sends the book title, author, and selected background image to a Python server (hosted on PythonAnywhere, free plan).  
The server generates the cover and sends it back to KOReader, where it is applied automatically.