"""iThoughts topic icon vocabulary.

`icon1`/`icon2` attributes hold an icon *name*.  The table maps each name to
  file      - PNG stem inside iThoughtsX.app/Contents/Resources/topic-icons
  label     - English label used by iThoughts
  emoji     - our own fallback rendering (no dependency on app resources)
  freemind  - FreeMind/Freeplane built-in icon name (for .mm export), or ""
Names not in the table (e.g. "icon-foo") are rendered via their file stem.
"""

# name: (file stem, label, emoji, freemind)
ICONS: dict[str, tuple[str, str, str, str]] = {
    "tick": ("green-tick", "Good", "✅", "button_ok"),
    "tickbox": ("tickbox", "Tickbox", "☑️", ""),
    **{f"p{i}": (f"p{i}", f"Priority {i}", f"{i}️⃣", f"full-{i}") for i in range(10)},
    "signal-flag-red": ("signal-flag-red", "Red flag", "🚩", "flag"),
    "signal-flag-yellow": ("signal-flag-yellow", "Yellow flag", "🟨", "flag-yellow"),
    "signal-flag-green": ("signal-flag-green", "Green flag", "🟩", "flag-green"),
    "icon-signal-flag-black": ("signal-flag-black", "Black Flag", "🏴", "flag-black"),
    "icon-signal-flag-blue": ("signal-flag-blue", "Blue Flag", "🟦", "flag-blue"),
    "icon-signal-flag-orange": ("signal-flag-orange", "Orange Flag", "🟧", "flag-orange"),
    "icon-signal-flag-purple": ("signal-flag-purple", "Purple flag", "🟪", "flag-pink"),
    "icon-signal-flag-white": ("signal-flag-white", "White Flag", "🏳️", ""),
    "icon-signal-flag-checkered": ("signal-flag-checkered", "Check Flag", "🏁", ""),
    "icon-hat-black": ("hat-black", "Black Hat", "🎩", ""),
    "icon-hat-blue": ("hat-blue", "Blue Hat", "🔵", ""),
    "icon-hat-green": ("hat-green", "Green Hat", "🟢", ""),
    "icon-hat-red": ("hat-red", "Red Hat", "🔴", ""),
    "icon-hat-white": ("hat-white", "White Hat", "⚪", ""),
    "icon-hat-yellow": ("hat-yellow", "Yellow Hat", "🟡", ""),
    "icon-calendar1": ("calendar1", "Calendar (day)", "📅", ""),
    "icon-calendar7": ("calendar7", "Calendar (week)", "📅", ""),
    "icon-calendar12": ("calendar12", "Calendar (month)", "📅", "calendar"),
    "icon-calendar31": ("calendar31", "Calendar (31)", "📅", ""),
    "icon-calendar52": ("calendar52", "Calendar (year)", "📅", ""),
    "arrow-down-blue": ("arrow-down-blue", "Down", "⬇️", "down"),
    "arrow-left-blue": ("arrow-left-blue", "Left", "⬅️", "back"),
    "arrow-right-blue": ("arrow-right-blue", "Right", "➡️", "forward"),
    "arrow-up-blue": ("arrow-up-blue", "Up", "⬆️", "up"),
    "arrow-up-green": ("arrow-up-green", "Rising", "📈", ""),
    "arrow-down-red": ("arrow-down-red", "Falling", "📉", ""),
    "stop": ("stop", "Red light", "🔴", "stop"),
    "prep": ("prepare", "Amber light", "🟠", "prepare"),
    "go": ("go", "Green light", "🟢", "go"),
    "smiley_happy": ("smiley-happy", "Happy", "😀", "ksmiletris"),
    "icon-smiley-neutral": ("smiley-neutral", "Smiley Neutral", "😐", "smiley-neutral"),
    "smiley_sad": ("smiley-sad", "Sad", "☹️", "smily_bad"),
    "icon-money": ("money", "Money", "💰", ""),
    "currency-dollar": ("currency-dollar", "Dollar", "💲", ""),
    "currency-euro": ("currency-euro", "Euro", "💶", ""),
    "currency-pound": ("currency-pound", "Sterling", "💷", ""),
    "currency-yen": ("currency-yen", "Yen", "💴", ""),
    "icon-currency-won": ("currency-won", "Won", "₩", ""),
    "icon-currency-yuan": ("currency-yuan", "Yuan", "¥", ""),
    "hand-yellow-card": ("hand-yellow-card", "Yellow card", "🟨", ""),
    "hand-red-card": ("hand-red-card", "Red card", "🟥", ""),
    "hand-stop": ("hand-stop", "Halt", "✋", ""),
    "hand-thumb-down": ("hand-thumb-down", "Thumbs down", "👎", ""),
    "hand-thumb-up": ("hand-thumb-up", "Thumbs up", "👍", ""),
    "question": ("question", "Question", "❓", "help"),
    "icon-questionmark": ("questionmark", "Question", "❔", ""),
    "icon-information": ("information", "Information", "ℹ️", ""),
    "icon-exclamationmark": ("exclamationmark", "Exclamation", "❗", "yes"),
    "alert": ("amber-alert", "Important", "⚠️", "messagebox_warning"),
    "icon-add": ("add", "Add", "➕", ""),
    "cross": ("red-cross", "Bad", "❌", "button_cancel"),
    "sign-forbidden": ("sign-forbidden", "Forbidden", "⛔", "closed"),
    "sign-stop": ("sign-stop", "Stop", "🛑", "stop-sign"),
    "idea": ("lightbulb", "Idea", "💡", "idea"),
    "icon-camera": ("camera", "Camera", "📷", ""),
    "auction-hammer": ("auction-hammer", "Decision", "🔨", ""),
    "bell": ("bell", "Bell", "🔔", ""),
    "bomb": ("bomb", "Bomb", "💣", "clanbomber"),
    "dynamite": ("dynamite", "Dynamite", "🧨", ""),
    "fire": ("fire", "Fire", "🔥", ""),
    "hourglass": ("hourglass", "Wait", "⏳", "hourglass"),
    "target": ("target", "Target", "🎯", ""),
    "view": ("view", "Find", "🔍", "xmag"),
    "icon-airplane": ("airplane", "Airplane", "✈️", ""),
    "icon-alarmclock": ("alarmclock", "Alarm Clock", "⏰", "clock"),
    "icon-bug": ("bug", "Bug", "🐞", ""),
    "icon-businessmen": ("businessmen", "Businessmen", "👥", "group"),
    "icon-car": ("car", "Car", "🚗", ""),
    "icon-clients": ("clients", "Clients", "🧑‍🤝‍🧑", ""),
    "icon-cup": ("cup", "Cup", "☕", ""),
    "icon-data": ("data", "Data", "🗄️", ""),
    "icon-desktop": ("desktop", "Computer", "🖥️", ""),
    "icon-earth": ("earth", "Earth", "🌍", ""),
    "icon-flash": ("flash", "Lightening", "⚡", ""),
    "icon-gear": ("gear", "Gear", "⚙️", ""),
    "icon-heart": ("heart", "Heart", "❤️", ""),
    "icon-key": ("key", "Key", "🔑", "password"),
    "icon-lock-open": ("lock-open", "Open Lock", "🔓", ""),
    "icon-lock": ("lock", "Closed Lock", "🔒", ""),
    "icon-mail": ("mail", "Mail", "✉️", "Mail"),
    "icon-pin": ("pin", "Pin", "📌", ""),
    "icon-printer": ("printer", "Printer", "🖨️", ""),
    "icon-scales": ("scales", "Scales", "⚖️", ""),
    "icon-star": ("star", "Star", "⭐", "bookmark"),
    "icon-telephone": ("telephone", "Telephone", "☎️", "kaddressbook"),
    "icon-pencil": ("pencil", "Pencil", "✏️", "pencil"),
    "icon-alarm": ("alarm", "Alarm", "🚨", ""),
    "icon-book": ("book", "Book", "📖", ""),
    "icon-certificate": ("certificate", "Certificate", "📜", ""),
    "icon-cloud": ("cloud", "Cloud", "☁️", ""),
    "icon-compasses": ("compasses", "Compasses", "📐", ""),
    "icon-dice": ("dice", "Dice", "🎲", ""),
    "icon-folder": ("folder", "Folder", "📁", ""),
    "icon-document": ("document", "Document", "📄", ""),
    "icon-male": ("male", "Male", "♂️", ""),
    "icon-female": ("female", "Female", "♀️", ""),
    "icon-newspaper": ("newspaper", "Newspaper", "📰", ""),
    "icon-paperclip": ("paperclip", "Paperclip", "📎", ""),
    "icon-presentation": ("presentation", "Presentation", "📊", ""),
    "icon-signpost": ("signpost", "Signpost", "🪧", ""),
    "icon-step": ("step", "Step", "👣", ""),
}


def info(name: str) -> tuple[str, str, str, str]:
    if name in ICONS:
        return ICONS[name]
    stem = name[5:] if name.startswith("icon-") else name
    return (stem, stem, "🔹", "")


def emoji(name: str) -> str:
    return info(name)[2]


def file_name(name: str) -> str:
    return f"icon-{info(name)[0]}@2x.png"


def as_json() -> dict:
    return {k: {"file": file_name(k), "label": v[1], "emoji": v[2]} for k, v in ICONS.items()}
