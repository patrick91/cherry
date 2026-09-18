#!/usr/bin/env python3
"""Produce a portable, offline HTML preview from the editable prototype files."""
import base64
import json
from pathlib import Path

root = Path(__file__).resolve().parent


def data_url(path, mime):
    return f"data:{mime};base64," + base64.b64encode(path.read_bytes()).decode()


html = (root / 'index.html').read_text()
css = (root / 'style.css').read_text()
js = (root / 'app.js').read_text()
font = data_url(root / 'assets/InterVariable.woff2', 'font/woff2')
logo = data_url(root / 'assets/cherry.png', 'image/png')
icons = {p.stem: data_url(p, 'image/svg+xml') for p in (root / 'assets').glob('*.svg')}
css = css.replace('url(assets/InterVariable.woff2)', f'url({font})')
css = css.replace('url(assets/chevron-down-dark.svg)', f'url({icons["chevron-down-dark"]})')
js = js.replace('url(assets/${name}.svg)', 'url(${embeddedIcons[name]})')
js = js.replace('src="assets/cherry.png"', f'src="{logo}"')
js = 'const embeddedIcons = ' + json.dumps(icons) + ';\n' + js
html = html.replace('  <link rel="preload" href="assets/InterVariable.woff2" as="font" type="font/woff2" crossorigin>\n', '')
html = html.replace('<link rel="stylesheet" href="style.css">', '<style>' + css + '</style>')
html = html.replace('<script src="app.js"></script>', '<script>' + js + '</script>')
html = html.replace('src="assets/cherry.png"', f'src="{logo}"')
licenses = '\n\n'.join(
    (root / 'assets' / filename).read_text()
    for filename in ['heroicons-LICENSE.txt', 'Inter-LICENSE.txt']
)
html = html.replace('</body>', '<script type="text/plain" id="asset-licenses">\n' + licenses + '\n</script>\n</body>')
out = root / 'Cherry sidebar studies.html'
out.write_text(html)
print(out)
