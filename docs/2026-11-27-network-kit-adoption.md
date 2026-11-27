# Network kit adoption

GSD adopts TaskVisualizationKit `6ca9c98a1115b7e33fa29855ae296a92c81e8eef` from the shared integration owner. The component passed all 27 original tests plus 7 additive title placement cases on Xcode 27.0. Original upstream sources and the Board/Flow test contracts are unchanged.

The adapter reserves every native node target while placing title labels and reserves a stable selected-title footer. This addresses the original iPhone screenshot where node circles crossed task title glyphs.

Qualification: `/mnt/development/projects/evidence/gsd-lorvex-integration-20261127/shared/network-6ca9c98a/KIT_ADOPTION_6ca9c98a.json`, SHA256 `7c6c95aa80a8cf68f6d081a1e9459b757f21ef7da15cc6f041a73552dfe01be0`.

This commit changes the authoritative XcodeGen manifest. The generated project and dependency locks must be regenerated and committed from the native Apple environment before the final source freeze. Final app build, Board/Network interaction, and English/Hebrew phone/tablet visual acceptance remain pending. Component test success does not assert host acceptance.
