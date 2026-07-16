#!/bin/bash

BASE_DIR="$(cd "$(dirname "$0")" || exit; pwd)"
LUCI_DIR="$BASE_DIR/../../luci"
SCAN_DIRS=(
	htdocs
	root/etc/homeproxy/scripts
	root/usr/share/luci
	root/usr/share/rpcd
)

cd "$BASE_DIR/.." || exit 1

if [ -d "$LUCI_DIR" ]; then
	perl "$LUCI_DIR/build/i18n-scan.pl" "${SCAN_DIRS[@]}" > po/templates/homeproxy.pot
	perl "$LUCI_DIR/build/i18n-update.pl" po
else
	LUCI_URL="https://raw.githubusercontent.com/openwrt/luci/691574263356689912c5bd31984bb1b96417a847"
	perl <(curl -fs "$LUCI_URL/build/i18n-scan.pl") "${SCAN_DIRS[@]}" > po/templates/homeproxy.pot
	perl <(curl -fs "$LUCI_URL/build/i18n-update.pl") po
fi
find po -name '*.po~' -delete
while IFS= read -r -d '' po_file; do
	msgattrib --no-obsolete -o "$po_file.new" "$po_file" && mv "$po_file.new" "$po_file"
done < <(find po -name '*.po' -print0)
