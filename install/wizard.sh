wizard() {

  # `exec wizard` DOES NOT CALL THIS FUNCTION. exec replaces the shell with an external COMMAND, and
  # there is no `wizard` binary on PATH -- so every menu item that "returned to the menu" actually
  # looked one up, failed, and took the whole `acc` process down with it. Thirteen of the sixteen
  # items did this. Returning instead hands control back to the caller, which loops (acc.sh).
  #
  # $TMPDIR is tmpfs and is wiped on every boot; option 4 launches $TMPDIR/accd through the symlink
  # that lives there. acc and acca both rebuild those links before using them and this did not, so
  # the wizard was the one front-end that stayed broken until something else happened to repair it.
  command -v ensure_tmpdir_links >/dev/null 2>&1 && ensure_tmpdir_links || :

  clear
  echo
  print_header

  echo
  { daemon_ctrl | sed "s/ $accVer ($accVerCode)//"; } || :
  echo

echo -n "1) $(print_lang)
2) $(print_cmds)
3) $(print_doc)
4) $(print_re_start_daemon)
5) $(print_stop_daemon)
6) $(print_export_logs)
7) $(print_charge_once)
8) $(print_uninstall)
9) $(print_edit config.txt)
a) $(print_reset_bs)
b) $(print_test_cs)
c) $(print_update)
d) $(print_flash_zips)
e) $(print_i)
f) $(print_undo)
z) $(print_exit)

#? "
  read -n 1 choice
  echo
  echo

  case $choice in

    1)
      . $execDir/set-prop.sh; set_prop --lang
      exec $TMPDIR/acc
    ;;

    2)
      . $execDir/print-help.sh
      print_help_ g
      edit $TMPDIR/.help
      return 0
    ;;

    3)
      edit $readMe g VIEW html
      edit ${readMe%html}md
      return 0
    ;;

    4)
      $TMPDIR/accd
      return 0
    ;;

    5)
      daemon_ctrl stop > /dev/null || :
      return 0
    ;;

    6)
      logf --export
      echo
      print_press_key
      read -n 1
      return 0
    ;;

    7)
      clear
      echo
      echo -n ""
      print_1shot
      echo
      echo
      echo -n "> "
      read level
      clear
      exec $TMPDIR/acc --full ${level-}
      unset level
      print_press_key
      read -n 1
      return 0
    ;;

    8)
      set +eu
      print_uninstall
      echo "> yes/no: "
      read ans
      [ .$ans = .yes ] || return 0
      exec $execDir/uninstall.sh
    ;;

    9)
      edit $config g
      edit $config
      return 0
    ;;

    a)
      resetbs
      return 0
    ;;

    b)
      $TMPDIR/acc --test || :
      print_press_key
      read -n 1
      return 0
    ;;

    c)
      $TMPDIR/acc --upgrade --changelog || :
      print_press_key
      read -n 1
      exec $TMPDIR/acc
    ;;

    d)
      (
        set +eux
        trap - EXIT
        $execDir/flash-zips.sh
      ) || :
      echo
      print_press_key
      read -n 1
      exec $TMPDIR/acc
    ;;

    e)
      . $execDir/batt-info.sh
      batt_info
      echo
      print_press_key
      read -n 1
      return 0
    ;;

    f)
      rollback -v
      echo "> yes/no: "
      read ans
      [ .$ans != .yes ] || rollback
      exec $TMPDIR/acc
    ;;

    z)
      exit 0
    ;;

    *)
      print_wip
      sleep 1
      return 0
    ;;
  esac
}
