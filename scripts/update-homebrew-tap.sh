#!/bin/sh
# Point the Homebrew tap (kadaliao/homebrew-tap) at a published release:
# reads SHA256SUMS from the GitHub release, writes Casks/suck-my-disk.rb (the
# app) and Formula/smd.rb (the CLI), commits and pushes. Run it after
# `gh release create`.
#
#   scripts/update-homebrew-tap.sh v<version>
#
#   TAP_DIR  a local clone of the tap; without it a temporary clone is used
#   PUSH=0   commit only (check the result in TAP_DIR, then push by hand)
set -eu

TAG="${1:-}"
case "$TAG" in
v[0-9]*.[0-9]*.[0-9]*) ;;
*)
	echo "usage: $0 v<major>.<minor>.<patch>" >&2
	exit 2
	;;
esac
version="${TAG#v}"
repo="kadaliao/suck-my-disk"
tap_repo="kadaliao/homebrew-tap"

work="$(mktemp -d "${TMPDIR:-/tmp}/smd-tap.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT TERM

gh release download "$TAG" --repo "$repo" --pattern SHA256SUMS --output "$work/SHA256SUMS"
sha() {
	value="$(awk -v name="$1" '$2 == name { print $1 }' "$work/SHA256SUMS")"
	case "$value" in
	*[!0-9a-f]* | "")
		echo "error: SHA256SUMS of $TAG has no $1" >&2
		exit 1
		;;
	esac
	[ "${#value}" -eq 64 ] || { echo "error: bad checksum for $1" >&2; exit 1; }
	printf '%s' "$value"
}
app="$(sha "SuckMyDisk-$version.zip")"
cli="$(sha "smd-$version-macos.zip")"

tap="${TAP_DIR:-}"
if [ -z "$tap" ]; then
	tap="$work/tap"
	gh repo clone "$tap_repo" "$tap" -- --quiet --depth 1
fi
mkdir -p "$tap/Formula" "$tap/Casks"

# The cask uses the same zip as the in-app updater; rename assets in
# release.sh, Update.swift and here together.
cat >"$tap/Casks/suck-my-disk.rb" <<EOF
cask "suck-my-disk" do
  version "$version"
  sha256 "$app"

  url "https://github.com/$repo/releases/download/v#{version}/SuckMyDisk-#{version}.zip"
  name "SuckMyDisk"
  desc "认得出项目、渲染帧、开发缓存、本地模型和应用的磁盘空间工具"
  homepage "https://github.com/$repo"

  livecheck do
    url :url
    strategy :github_latest
  end

  # 应用每天自己检查 GitHub Releases 并更新，brew upgrade 默认跳过。
  auto_updates true
  depends_on macos: :tahoe

  app "SuckMyDisk.app"

  uninstall quit: "com.kadaliao.SuckMyDisk"

  # 索引、清理记录（含恢复命令）和设置。
  zap trash: [
    "~/Library/Application Support/SuckMyDisk",
    "~/Library/Caches/com.kadaliao.SuckMyDisk",
    "~/Library/HTTPStorages/com.kadaliao.SuckMyDisk",
    "~/Library/Preferences/com.kadaliao.SuckMyDisk.plist",
    "~/Library/Saved Application State/com.kadaliao.SuckMyDisk.savedState",
  ]
end
EOF

cat >"$tap/Formula/smd.rb" <<EOF
class Smd < Formula
  desc "SuckMyDisk 的命令行：看空间被谁占了、按预选清理，可输出 JSON"
  homepage "https://github.com/$repo"
  url "https://github.com/$repo/releases/download/v$version/smd-$version-macos.zip"
  sha256 "$cli"
  license "MIT"

  livecheck do
    url :stable
    strategy :github_latest
  end

  depends_on macos: :tahoe

  def install
    bin.install "smd"
  end

  def caveats
    <<~EOS
      smd 和 SuckMyDisk App 共用索引和清理记录。想要 App：
        brew install --cask kadaliao/tap/suck-my-disk
    EOS
  end

  test do
    assert_match "smd things", shell_output("#{bin}/smd help")
  end
end
EOF

git -C "$tap" add Casks/suck-my-disk.rb Formula/smd.rb
if git -C "$tap" diff --cached --quiet; then
	echo "The tap already has $version."
	exit 0
fi
git -C "$tap" commit --quiet -m "suck-my-disk $version, smd $version"
if [ "${PUSH:-1}" = "0" ]; then
	echo "Committed in $tap, not pushed."
	exit 0
fi
git -C "$tap" push --quiet
echo "Homebrew tap updated to $version."
