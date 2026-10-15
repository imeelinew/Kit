# Symbols Nerd Font Mono (embedded)

- Source: https://github.com/ryanoasis/nerd-fonts/releases/tag/v3.5.0
- File: `SymbolsNerdFontMono-Regular.ttf` from `NerdFontsSymbolsOnly.zip`
- License: see `NerdFontsSymbolsOnly-LICENSE.txt` and https://github.com/ryanoasis/nerd-fonts

# JetBrains Mono (embedded)

- Source: https://github.com/JetBrains/JetBrainsMono/tree/v2.304
- File: `JetBrainsMono-Regular.ttf`
- License: see `JetBrainsMono-LICENSE.txt`

# LXGW Neo XiHei (embedded)

- Source: https://github.com/lxgw/LxgwNeoXiHei/releases/tag/v1.305
- File: `LXGWNeoXiHei.ttf`, distributed without modification
- License: see `LXGWNeoXiHei-LICENSE.txt`
- English and digits continue to use JetBrains Mono, Chinese uses LXGW Neo XiHei

## Replacing LXGW Neo XiHei with the original IPA font

Download IPAex Gothic from https://moji.or.jp/ipafont/ipafontdownload/ and replace `/Applications/Kit.app/Contents/Resources/LXGWNeoXiHei.ttf` with `ipaexg.ttf`, retaining the destination filename

Re-sign the local app with `codesign --force --deep --sign - /Applications/Kit.app`, then restart Kit

Kit reads the embedded font descriptor, so the replacement can retain its original internal font name
