trap 'echo TRAP-FIRED-in-\$BASHPID=$$' EXIT
( exit 0 )
echo after-sub
