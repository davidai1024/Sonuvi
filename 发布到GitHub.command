#!/bin/zsh
cd -- "${0:A:h}" || exit 1
/usr/bin/python3 scripts/release.py publish "$@"
release_status=$?
printf '\n按回车关闭窗口。'
read -r
exit "$release_status"
