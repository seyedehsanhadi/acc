# Français (fr)

print_already_running() {
  echo "accd est déjà en fonctionnement"
}

print_started() {
  echo "accd lancé"
}

print_stopped() {
  echo "accd arrêté"
}

print_not_running() {
  echo "accd n'est pas en fonctionnement"
}

print_restarted() {
  echo "accd redémarré"
}

print_is_running() {
  echo "accd $1 est en fonctionnement $2"
}

print_config_reset() {
  echo "Configuration remise à zéro"
}

print_invalid_switch() {
  echo "Commutateur de charge invalide, [${chargingSwitch[@]-}]"
}

print_charging_disabled_until() {
  echo "Charge désactivée tant que la capatité de la batterie <= $1"
}

print_charging_disabled_for() {
  echo "Charge désactivée pendant $1"
}

print_charging_disabled() {
  echo "Charge désactivée"
}

print_charging_enabled_until() {
  echo "Charge activée tant que la capacité de la batterie >= $1"
}

print_charging_enabled_for() {
  echo "Charge activée pendant $1"
}

print_charging_enabled() {
  echo "Charge activée"
}

print_unplugged() {
  printf "Assurez-vous que le chargeur est branché 🔌\n\n"
}

print_switch_works() {
  echo "  Le commutateur fonctionne ✅"
}

print_switch_fails() {
  echo "  Le commutateur ne fonctionne pas ❌"
}

print_no_ctrl_file() {
  echo "Aucun fichier de contrôle n'a été trouvé"
}

print_not_found() {
  echo "$1 non trouvé"
}


print_help() {
  cat << EOF
Utilisation

  acc   Assistant

  accd   Démarrer/arrêter accd

  accd.   Arrêter acc/daemon

  accd,   Afficher le status acc/daemon (fonctionne ou pas)

  acc [pause_capacity/millivolts [resume_capacity/millivolts, défault: pause_capacity/millivolts - 5%/50mV]]
    ex,
      acc 75 70
      acc 80 (resume_capacity par défaut 80% - 5)
      acc 3900 (pareil que acc 3900 3870, bonne alternative au mode inactif (idle)

  acc [options] [args]   Se référer à la liste des options en-dessous

  acca [options] [args]   acc optimisé pour le "front-end"

  acc[d] -x [options] [args]   Définit log=/sdcard/Download/acc[d]-\${appareil}.log; utile pour le débogage de redémarrages non-voulus

  Un chemin customisé peut-être spécifié en premier paramètre (second si -x est utilisé).
  Si le fichier n'existe pas, la configuration actuelle est clonée.
    ex,
      acc /data/acc-night-config.txt --set pause_capacity=45 resume_capacity=43
      acc /data/acc-night-config.txt --set --current 500
      accd /data/acc-night-config.txt --init

  Notes pour accd:
    - L'ordre "--init|-i" n'as pas d'importance.
    - La chaîne de caractères du chemin de configuration ne doit pas contenir "--init|-i".


Options

  -b|--rollback   Annuler la mise à jour

  -c|--config [éditeur] [éditeur_opts]   Éditer la configuration (éditeur par défaut: nano/vim/vi)
    ex,
      acc -c (edit w/ nano/vim/vi)
      acc -c less
      acc -c cat

  -d|--disable [#%, #s, #m or #h (optionnel)]   Désactive la charge
    ex,
      acc -d 70% (ne pas recharger tant ue la capacité <= 70%)
      acc -d 1h (ne pas recharger avant qu'une heure ne soit passée)

  -D|--daemon   Affiche le status du daemon, (et si il est en fonctionnement) version et PID
    ex, acc -D (alias: "accd,")

  -D|--daemon [start|stop|restart]   Gérer le daemon
    ex,
      acc -D start (alias: accd)
      acc -D restart (alias: accd)
      accd -D stop (alias: "accd.")

  -e|--enable [#%, #s, #m or #h (optionnel)]   Active la charge
    ex,
      acc -e 75% (recharger à 75%)
      acc -e 30m (recharge pendant 30 minutes)

  -f|--force|--full [capacité]   Charger une fois à la capacité donnée (defaut: 100%), sans restrictions
    ex,
      acc -f 95 (charger à 95%)
      acc -f (charger à 100%)
    Note: si la capacité désirée est moindre que pause_capacity, utiliser acc -e #%

  -F|--flash ["fichier_zip"]   Flasher tous les fichiers zip dont le binaire de mise à jour est un script shell
    ex,
      acc -F (lance un assistant de flashage zip)
      acc -F "file1" "file2" "fileN" ... (installer plusieurs zips)
      acc -F "/sdcard/Download/Magisk-v20.0(20000).zip"

  -i|--info [insensible à la casse egrep regex (defaut: ".")]   Affiche les infos de la batterie
    ex,
      acc -i
      acc -i volt
      acc -i 'volt\|curr'

  -l|--log [-a|--acc] [éditeur] [éditeur_opts]   Affiche/modifie accd log (defaut) ou acc log (-a|--acc)
    ex,
      acc -l (identique à acc -l less)
      acc -l rm
      acc -l -a cat
      acc -l grep ': ' (affiche les erreurs explicites seulement)

  -la   Identique à -l -a

  -l|--log -e|--export   Exporte tout les logs dans /sdcard/Download/acc-logs-\$deviceName.tgz
    ex, acc -l -e

  -le   Identique à -l -e

  -n|--notif [["STRING" (défaut: ":)")] [USER ID (défaut: 2000 (shell))]]   Affiche une notification Android; peut ne pas marcher sur tout les systèmes
    ex, acc -n "Hello, World!"

  -p|--parse [<fichier de base> <fichier à analyser>] | <fichier à analyser>]   Aide à trouver les potentiels commutateurs de charge rapidement, pour tout appareil
    ex,
      acc -p   Analyse $dataDir/logs/power_supply-\*.log et affiche les commutateurs de charge potentiels non présent dans $TMPDIR/ch-switches
      acc -p /sdcard/power_supply-harpia.log   Analyse le fichier donné et affiche les commutateurs de charge potentiels qui ne sont pas dans $TMPDIR/ch-switches
      acc -p /sdcard/charging-switches.txt /sdcard/power_supply-harpia.log   Analyse /sdcard/power_supply-harpia.log et affiche les commutateurs de charge potentiels absents depuis /sdcard/charging-switches.txt

  -r|--readme [éditeur] [éditeur_opts]   Affiche/édite README.md
    ex,
      acc -r (pareil que acc -r less)
      acc -r cat

  -R|--resetbs   Remise à zéro des statistiques de la batterie (paramètres > batterie > utilisation de la batterie)
    ex, acc -R

  -s|--set   Affiche la configuration actuelle
    ex, acc -s

  -s|--set prop1=valeur "prop2=valeur1 valeur2"   Définit [plusieurs] propriétées
    ex,
      acc -s charging_switch=
      acc -s pause_capacity=60 resume_capacity=55 (raccourcis: acc -s pc=60 rc=55, acc 60 55)
      acc -s "charging_switch=battery/charging_enabled 1 0" resume_capacity=55 pause_capacity=60
    Note: toutes les propriétées ont des alias pour une écriture plus rapide; faire "acc -c cat" pour les voir

  -s|--set [sd|sched]="[+-](programme à ajouter ou à supprimer)" (2050 correspond à 20H50)
    ex,
      acc -s sd=-2050 (supprime le programme qui corrrespond à 2050)
      acc -s sd="+2200 acc -s mcv=3900 mcc=500; acc -n "Changé sur le profile \"nuit\"" (ajoute un programme à 22H00, et affiche une notification lors du changement)
    Note: "acc -s sd=" se comporte comme les autres commandes (restaure les valeurs pas défaut; pour les programmes, c'est vide)

  -s|--set c|--current [milliamps|-]   Définit/affiche/restaure_défaut le courant de charge maximum (compris entre: 0-9999$(print_mA))
    ex,
      acc -s c (affiche la limite actuelle)
      acc -s c 500 (définit "500" comme valeur maximum)
      acc -s c - (restaure aux paramètres par défaut)

  -sc [milliamps|-]   Pareil qu'au dessus

  -s|--set l|--lang   Change le language
    ex, acc -s l

  -sl   Pareil qu'au dessus

  -s|--set d|--print-default [egrep regex (défaut: ".")]   Affiche la configuration par défaut sans lignes vides
    ex,
      acc -s d (affiche l'entièreté de la configuration par défaut)
      acc -s d cap (affiche seulement les entrées correspondantes à "cap")

  -sd [egrep regex (default: ".")]   Pareil qu'au dessus

  -s|--set p|--print [egrep regex (défaut: ".")]   Affiche la configuration par défaut sans lignes vides (se référer aux exemples précédents)

  -sp [egrep regex (défaut: ".")]  Pareil qu'au dessus

  -s|--set r|--reset [a]   Restaure la configuration pas défaut ("a" est pour "all": configure et contrôle les fichiers en liste noire, essentiellement un remise à zéro)
      e.x,
      acc -s r

  -sr [a]  Pareil qu'au dessus


  -s|--set s|charging_switch   Force l'utilisation d'un commutateur de charge spécifique
    ex, acc -s s

  -ss    Pareil qu'au desssus

  -s|--set s:|chargingSwitch:   Liste les commutateurs de charge connus
    ex, acc -s s:

  -ss:   Pareil qu'au dessus

  -s|--set v|--voltage [millivolts|-] [--exit]   Définit/affiche/restaure le voltage de charge maximum (compris entre: 3700-4300$(print_mV))
    ex,
      acc -s v (affiche)
      acc -s v 3900 (définit)
      acc -s v - (restaure défaut)
      acc -s v 3900 --exit (arrête le daemon après l'application des changements)

  -sv [millivolts|-] [--exit]   Pareil qu'au dessus

  -t|--test [fichier_ctrl1 on off [fichier_ctrl2 on off]]   Teste des commutateurs de charge custom
    ex,
      acc -t battery/charging_enabled 1 0
      acc -t /proc/mtk_battery_cmd/current_cmd 0::0 0::1 /proc/mtk_battery_cmd/en_power_path 1 0 ("::" est un remplacent pour " " - MTK seulement)

  -t|--test [fichier]   Teste des commutateurs de charge depuis un fichier (défaut: $TMPDIR/ch-switches)
    ex,
      acc -t (teste les commutateurs connus)
      acc -t /sdcard/experimental_switches.txt (teste des commutateurs custom/étrangers)

  -t|--test [p|parse]   Analyse les potentiels commutateurs de charge depuis le log d'alimentation (comme "acc -p"), les teste tous, et ajoute ceux qui fonctionne à la liste des commutateurs connus
    Implique -x, comme acc -x -t p
    ex, acc -t p

  -T|--logtail   Surveille le log accd (suivre -F)
    ex, acc -T

  -u|--upgrade [-c|--changelog] [-f|--force] [-k|--insecure] [-n|--non-interactive]   Mise à jour/rétrograde en ligne
    ex,
      acc -u dev (met à jour par rapport à la dernière version dev)
      acc -u (dernière version de la branche actuelle)
      acc -u master^1 -f (avant dernière sortie stable)
      acc -u -f dev^2 (deux versions dev avant la dernière version dev)
      acc -u v2020.4.8-beta --force (force la mise à jour/rétrograde à v2020.4.8-beta)
      acc -u -c -n (si une mise à jour est diponible, affiche le code de version (nombre entier) et le lien du journal des modifications)
      acc -u -c (pareil qu'au dessus, mais avec une invité d'installation)

  -U|--uninstall   Désinstalle comptètement acc et AccA
    ex, acc -U

  -v|--version   Affiche la version de acc et le code de version
    ex, acc -v

  -w#|--watch#   Surveiller les événements de la batterie
    ex,
      acc -w (rafraichît les infos toutes les 3 secondes)
      acc -w0.5 (rafraichît les infos toutes les 0.5 secondes)
      acc -w0 (aucun délais d'attente)


Codes de sortie

  0. Vrai/succès
  1. Faux/défaillance générale
  2. Syntaxe de commande incorrecte
  3. Il manque un binaire busybox
  4. N'est pas lancé en tant que superutilisateur
  5. Mise à jour disponible ("--upgrade")
  6. Pas de mise à jour disponible ("--upgrade")
  7. N'a pas pu arrêter le chargement
  8. Le daemon et déjà lancé ("--daemon start")
  9. Le daemon n'est pas lancé ("--daemon" and "--daemon stop")
  10. Tout les commutateurs de charge ont échoués (--test)
  11. Le courant (mA) n'est pas compris entre 0 et 9999
  12. L'initialisation à échouée
  13. Échec du vérrouillage de $TMPDIR/acc.lock
  14. ACC ne peut pas s'initialiser, car le module Magisk est désactivé
  15. Le mode de veille est supporté (--test)
  16. N'a pas pu activer le chargement (--test)

  Les logs sont exportés automatiquement ("--log --export") lors des codes de sortie 7 et 10.


Astuces

  Les commandes peuvent être mise à la chaîne pour des fonctionalitées étendues.
    ex, charge pendant 30 minutes, arrête le chargement pendant 6 heures, charge jusqu'à 85% et redémarre le daemon
    acc -e 30m && acc -d 6h && acc -e 85 && accd

  Profile exemple
    acc -s pc=45 rc=43 mcc=500 mcv=3900
      Ceci garde le niveau de la batterie entre 43-45%, limite le courant de charge à 500 mA et le voltage à 3900 millivolts.
      C'est adapté pour le branchement nocturne et pour le "toujours branché".

  Se référer à acc -r (ou --readme) pour la documentation complète (recomendé)
EOF
}


print_exit() {
  echo "Sortie"
}

print_choice_prompt() {
  echo "(?) Choix, [Entrée]: "
}

print_auto() {
  echo "Automatique"
}

print_default() {
 echo "Défaut"
}

print_curr_restored() {
  echo "Courant de charge par défaut restauré"
}

print_volt_restored() {
  echo "Voltage de charge par défaut restauré"
}

print_read_curr() {
  echo "Besoin de lire les valeur(s) par défaut du courant maximum de charge en premier"
}

print_curr_set() {
  echo "courant maximum de charge défini à $1$(print_mA)"
}

print_volt_set() {
  echo "Voltage maximum de charge défini à $1$(print_mV)"
}

print_wip() {
  echo "Option invalide"
  echo "- Essayer acc -y ou -r pour aficher un message d'aide "
}

print_press_key() {
  printf "Presser n'importe quelle touche pour continuer..."
}

print_lang() {
  echo "Langage 🌐"
}

print_doc() {
  echo "Documentation 📘"
}

print_cmds() {
  echo "Toutes les commandes"
}

print_re_start_daemon() {
  echo "Démarrer/arrêter le daemon ▶️ 🔁"
}

print_stop_daemon() {
  echo "Arrêter le daemon ⏹️"
}

print_export_logs() {
  echo "Exporter les logs"
}

print_1shot() {
  echo "Charger une fois à la capacité donnée (défaut: 100%), sans restrictions"
}

print_charge_once() {
  echo "Charger une fois à #%"
}

print_mA() {
  echo " Milliampères"
}

print_mV() {
  echo " Millivolts"
}

print_uninstall() {
  echo "Désinstaller"
}

print_edit() {
  echo "Editer $1"
}

print_flash_zips() {
  echo "Flasher des zips"
}

print_reset_bs() {
  echo "Remettre à zéro les statistiques de la batterie"
}

print_test_cs() {
  echo "Tester les commutateurs de charge"
}

print_update() {
  echo "Vérifier pour des mises à jour 🔃"
}

print_W() {
  echo " Watts"
}

print_V() {
  echo " Volts"
}

print_available() {
  echo "$@ est disponible"
}

print_install_prompt() {
  printf "- Télécharger et installer ([Entrée]: oui, CTRL-C: non)? "
}

print_no_update() {
  echo "Pas de mise à jour disponible"
}

print_A() {
  echo " Ampères"
}

print_only() {
  echo "seulement"
}

print_wait() {
  echo "Cela peut prendre du temps... ⏳"
}

print_as_warning() {
  echo "⚠️ ATTENTION: Le système s'arrêtera à ${1}% de batterie si aucun chargeur n'est branché !"
}

print_i() {
  echo "Informations sur la batterie"
}

print_undo() {
  echo "Annuler la mise à jour"
}

print_blacklisted() {
  echo "  Le commutateur est sur la lista noire; il ne sera plus testé 🚫"
}


print_acct_info() {
  echo "
💡 Notes/Astuces:

  - Certains commutateurs -- notament ceux qui contrôle le courant et le voltage -- peuvent avoir des inconsistances. Si un commutateur marche au moins deux fois, il est considéré comme fonctionnel.

  - Les résultats peuvent varier en fonction des contitions ou des chargeurs différents, comme écrit dans \"readme > troubleshooting > charging switch\".

  - Envie de tester tout les commutateurs potentiels ? \"acc -t p\" les récupère depuis le ficier log de l'alimentation (comme \"acc -p\"), les teste tous, et ajoute les fonctionnels à la liste des commutateurs connus.

  - Pour définir les commutateurs de charge, faire acc -ss (assistant) ou acc -s s=\"commutateurs ici --\".

  - idleMode (mode de veille): quand l'appareil peut fonctionner dirrectement sur le chargeur.

  - La sortie de cette commande est sauvegardée dans /sdcard/Download/acc-t_output-${device}.log."
}


print_panic() {
  printf "\nATTENTION: fonctionalitée extérimentale, dragons à bâbord!
Certains fichiers de contrôle problématiques sont mis sur le liste noire automatiquement, basé sur des paternes connus.
Voulez-vous voir/éditer la liste des commutateurs potentiels avant de les tester ?
a: annuler l'opération | n: non | y: oui (défaut) "
}
