#!/bin/zsh
PROJECT_DIR="${0:A:h}"
/bin/zsh "$PROJECT_DIR/install.sh" "$@"
RESULT=$?
if [[ -t 0 ]]; then
  if (( RESULT == 0 )); then print '\n已完成，可以关闭此窗口。'; else print '\n安装未完成，请查看上方说明。'; fi
  read '?按回车关闭…'
fi
exit "$RESULT"
