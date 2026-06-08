package com.shogun.android.ui.theme

import androidx.compose.ui.graphics.Color

// ━━ Sengoku Color Palette ━━
// Based on .interface-design/system.md

// Primitives
val Shikkoku = Color(0xFF1A1A1A)  // Shikkoku (Jet Black) — lacquered armor base
val Sumi     = Color(0xFF2D2D2D)  // Sumi (Ink Black) — ink stone, castle wall
val Kinpaku  = Color(0xFFC9A94E)  // Kinpaku (Gold Leaf) — gold leaf on shrine
val Zouge    = Color(0xFFE8DCC8)  // Zouge (Ivory) — washi paper, scroll
val Shuaka   = Color(0xFFB33B24)  // Shuaka (Vermilion) — vermilion torii gate
val Matsuba  = Color(0xFF3C6E47)  // Matsuba (Pine Needle Green) — pine garden (success)
val Tetsukon = Color(0xFF3A4A5C)  // Tetsukon (Iron Blue) — iron armor plate
val Kurenai  = Color(0xFFCC3333)  // Kurenai (Crimson Red) — blood red (error)

// Surface elevation
val Surface0 = Color(0xFF1A1A1A)  // Screen background
val Surface1 = Color(0xFF2D2D2D)  // Cards, pane tiles
val Surface2 = Color(0xFF363636)  // Dropdowns, dialogs
val Surface3 = Color(0xFF404040)  // Modals, fullscreen overlays
val Surface4 = Color(0xFF1E1E1E)  // Input field (inset, darker than surroundings)

// Text hierarchy
val TextPrimary   = Color(0xFFC9A94E)  // Kinpaku — headings, agent names, tab labels
val TextSecondary = Color(0xFFE8DCC8)  // Zouge — body text, terminal output
val TextTertiary  = Color(0xFF8A9BB0)  // Lightened Tetsukon — metadata, timestamps
val TextMuted     = Color(0xFF666666)  // Disabled, placeholders

// Borders — Kinpaku at opacity levels
val BorderStandard = Color(0x33C9A94E)  // 20% opacity
val BorderEmphasis = Color(0x66C9A94E)  // 40% opacity
val BorderFocus    = Color(0x99C9A94E)  // 60% opacity

// Status — Jinmaku bar
val StatusConnected    = Matsuba  // #3C6E47 green
val StatusDisconnected = Kurenai  // #CC3333 red
val StatusReconnecting = Kinpaku  // #C9A94E gold pulsing

// Dashboard markdown
val LinkGold = Color(0xFFD4B96A)  // lighter gold for links
