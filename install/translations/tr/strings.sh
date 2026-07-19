# Türkçe (tr)

print_already_running() {
  echo "accd zaten çalışıyor"
}

print_started() {
  echo "accd başlatıldı"
}

print_stopped() {
  echo "accd durduruldu"
}

print_not_running() {
  echo "accd çalışmıyor"
}

print_restarted() {
  echo "accd yeniden başlatıldı"
}

print_is_running() {
  echo "accd $1 - $2 kodlu işlemi çalıştırıyor"
}

print_config_reset() {
  echo "Ayarlar sıfırlandı"
}

print_invalid_switch() {
  echo "Geçersiz şarj portu, [${chargingSwitch[@]-}]"
}

print_charging_disabled_until() {
  echo "Batarya seviyesi <= $1 olana kadar şarj devre dışı bırakldı"
}

print_charging_disabled_for() {
  echo "$1 süreliğine şarj devre dışı bırakldı"
}

print_charging_disabled() {
  echo "Şarj devre dışı bırakıldı"
}

print_charging_enabled_until() {
  echo "Batarya seviyesi >= $1 olana kadar şarj devre dışı bırakıldı"
}

print_charging_enabled_for() {
  echo "$1 süreliğine şarj aktif edildi"
}

print_charging_enabled() {
  echo "Şarj aktif edildi"
}

print_unplugged() {
  printf "Şarj kablosunun bağlı olduğundan emin ol 🔌\n\n"
}

print_switch_works() {
  echo "  Port çalışıyor ✅"
}

print_switch_fails() {
  echo "  Port çalışmıyor ❌"
}

print_no_ctrl_file() {
  echo "Kontrol dosyası bulunamadı"
}

print_not_found() {
  echo "$1 bulunamadı"
}


print_help() {
  cat << EOF
Kullanım

  acc    Asistan

  accd   accd başlat/yeniden başlat

  accd.  acc/daemon durdur

  accd,  acc/daemon durumunu yazdır (çalışıyor veya çalışmıyor)

  acc [pause_capacity/millivolts [resume_capacity/millivolts, varsayılan: pause_capacity/millivolts - 5%/50mV]]
    e.g.,
      acc 75 70
      acc 80 (resume_capacity 80% - 5 yapılır)
      acc 3900 (acc 3900 3870 ile aynı, idle mod için alternatif)

  acc [options] [args]   Opsiyonlar listesi için aşağıya bakın

  acca [options] [args]   front-end için acca

  acc[d] -x [options] [args]   Sets log=/sdcard/Download/acc[d]-\${device}.log; istenmeyen reboot durumlarında debug(hata ayıklama) için kullanışlı

  İlk parametre yerine özel bir ayar dosyası dizini belirtilebilir (eğer -x kullanıldı ise ikinci parametre).
  Eğer böyle bir dosya yoksa, mevcut ayarlar kopyalanır.
    e.g.,
      acc /data/acc-night-config.txt --set pause_capacity=45 resume_capacity=43
      acc /data/acc-night-config.txt --set --current 500
      accd /data/acc-night-config.txt --init

  accd için notlar:
    - "--init|-i" sıralaması önemli değil.
    - Ayar dosyası dizini "--init|-i" içermemeli.


Options

  -b|--rollback   Güncellemeyi geri al

  -c|--config [editor] [editor_opts]   Ayarları düzenle (varsayılan editör: nano/vim/vi)
    e.g.,
      acc -c (nano/vim/vi kullanarak düzenle)
      acc -c less
      acc -c cat

  -d|--disable [#%, #s, #m or #h (optional)]   Şarjı devre dışı bırak
    e.g.,
      acc -d 70% (şarj seviyesi <= 70% olana kadar şarj etme)
      acc -d 1h (1 saat boyunca şarj etme)

  -D|--daemon   daemon durumunu yazdır, (eğer çalışıyorsa) versiyon ve PID
    e.g., acc -D (namıdiğer: "accd,")

  -D|--daemon [start|stop|restart]   daemon kontrolü
    e.g.,
      acc -D start (namıdiğer: accd)
      acc -D restart (namıdiğer: accd)
      accd -D stop (namıdiğer: "accd.")

  -e|--enable [#%, #s, #m or #h (optional)]   Şarjı aktif et
    e.g.,
      acc -e 75% (75%'e kadar şarj et)
      acc -e 30m (30 dakika şarj et)

  -f|--force|--full [capacity]   Bir kereliğine verilen seviyeye kadar şarj et (varsayılan: 100%), kısıtlamalar olmadan
    e.g.,
      acc -f 95 (95%'e kadar şarj et)
      acc -f (100%'e kadar şarj et)
    Note: Eğer istediğiniz seviye [pause_capacity]'den küçükse, acc -e #% kullanın

  -F|--flash ["zip_file"]   update-binary olarak shell-script kullanan herhangi bir zip dosyası yükle
    e.g.,
      acc -F (zip yükleme asistanını başlatır)
      acc -F "file1" "file2" "fileN" ... (birden fazla zip yükle)
      acc -F "/sdcard/Download/Magisk-v20.0(20000).zip"

  -i|--info [case insensitive egrep regex (default: ".")]   Batarya bilgisini göster
    e.g.,
      acc -i
      acc -i volt
      acc -i 'volt\|curr'

  -l|--log [-a|--acc] [editor] [editor_opts]   accd log yazdır/düzenle (varsayılan) veya acc log (-a|--acc)
    e.g.,
      acc -l (acc -l less ile aynı)
      acc -l rm
      acc -l -a cat
      acc -l grep ': ' (bariz hataları göster)

  -la   Same as -l -a

  -l|--log -e|--export   Bütün logları /sdcard/Download/acc-logs-$deviceName.tgz dizinine çıkart
    e.g., acc -l -e

  -le   Same as -l -e

  -n|--notif [["STRING" (default: ":)")] [USER ID (default: 2000 (shell))]]   Android bildirimi; her sistemde çalışmayabilir
    e.g., acc -n "Hello, World!"

  -p|--parse [<base file> <file to parse>] | <file to parse>]   Şarj portlarını hızlıca bulmaya yardımcı olur, herhangi bir cihaz için
    e.g.,
      acc -p   $dataDir/logs/power_supply-\*.log oluştur $TMPDIR/ch-switches içinde olmayan şarj portlarını yazdır
      acc -p /sdcard/power_supply-harpia.log verilen dizini oluştur ve $TMPDIR/ch-switches içinde olmayan şarj portlarını yazdır
      acc -p /sdcard/charging-switches.txt /sdcard/power_supply-harpia.log  /sdcard/power_supply-harpia.log dizinini oluştur ve /sdcard/charging-switches.txt içinde olmayan şarj portlarını yazdır

  -r|--readme [editor] [editor_opts]   Yazdır/düzenle README.md
    e.g.,
      acc -r (same as acc -r less)
      acc -r cat

  -R|--resetbs   Batarya istatistiklerini sıfırla
    e.g., acc -R

  -s|--set   Kullanılan ayarları yazdır
    e.g., acc -s

  -s|--set prop1=value "prop2=value1 value2"   [birden fazla] özellik ayarla
    e.g.,
      acc -s charging_switch=
      acc -s pause_capacity=60 resume_capacity=55 (kısayollar: acc -s pc=60 rc=55, acc 60 55)
      acc -s "charging_switch=battery/charging_enabled 1 0" resume_capacity=55 pause_capacity=60
    Not: her şeyin hızlıca yazmak için bir kısayolu var; görmek için "acc -c cat"

  -s|--set [sd|sched]="[+-]profil ayarlar veya kaldır"
    e.g.,
      acc -s sd=-2050 (2050 ile eşleşenleri kaldır)
      acc -s sd="+2200 acc -s mcv=3900 mcc=500; acc -n "Switched to \"sleep\" profile" (append schedule)
    Not: "acc -s sd=" aynı diğer basit komutlar gibi çalışır (varsayılan değeri yükler; varsayılan değer: null, profiller için)

  -s|--set c|--current [milliamps|-]   Maksimum şarj akımı ayarla/yazdır/varsayılana döndür (aralık: 0-9999$(print_mA))
    e.g.,
      acc -s c (şu anki limiti yazdır)
      acc -s c 500 (ayarla)
      acc -s c - (varsayılana döndür)

  -sc [milliamps|-]   Yukarıdaki ile aynı

  -s|--set l|--lang   Dil değiştir
    e.g., acc -s l

  -sl   Yukarıdaki ile aynı

  -s|--set d|--print-default [egrep regex (default: ".")]   Varsayılan ayaları yazdır, boşluk olmadan
    e.g.,
      acc -s d (bütün varsayılan ayarları yazdır)
      acc -s d cap (yalnızca "cap" ile eşleşen girdileri yazdır)

  -sd [egrep regex (default: ".")]   Yukarıdaki ile aynı

  -s|--set p|--print [egrep regex (default: ".")]   Varsayılan ayaları yazdır, boşluk olmadan (önceki örneklere bakın)

  -sp [egrep regex (default: ".")]   Yukarıdaki ile aynı

  -s|--set r|--reset [a]   Varsayılan ayaları yükle ("a", "all" tamamı için: ayar ve kontrol dosyaları, kökten bir sıfırlama)
    e.g.,
      acc -s r

  -sr [a]   Yukarıdaki ile aynı


  -s|--set s|charging_switch   Bir şarj portunu seç
    e.g., acc -s s

  -ss    Yukarıdaki ile aynı

  -s|--set s:|chargingSwitch:   Bilinen şarj portlarını listele
    e.g., acc -s s:

  -ss:   Yukarıdaki ile aynı

  -s|--set v|--voltage [millivolts|-] [--exit]   Maksimum şarj voltajı ayarla/yazdır/varsayılana döndür (range: 3700-4300$(print_mV))
    e.g.,
      acc -s v (yazdır)
      acc -s v 3900 (ayarla)
      acc -s v - (varsayılana döndür)
      acc -s v 3900 --exit (ayaları uyguladıktan sonra daemon durdur)

  -sv [millivolts|-] [--exit]   Yukarıdaki ile aynı

  -t|--test [ctrl_file1 on off [ctrl_file2 on off]]   Özel şarj portlarını test et
    e.g.,
      acc -t battery/charging_enabled 1 0
      acc -t /proc/mtk_battery_cmd/current_cmd 0::0 0::1 /proc/mtk_battery_cmd/en_power_path 1 0 ("::" yerini tutar -> " " - MTK only)

  -t|--test [file]   Bir dosyadaki şarj portlarını test et (varsayılan: $TMPDIR/ch-switches)
    e.g.,
      acc -t (bilinen portları test et)
      acc -t /sdcard/experimental_switches.txt (özel/bilinmeyen portları test et)

  -t|--test [p|parse]   Potansiyel şarj portlarını güç kaynağı loglarından (aynı "acc -p" gibi) al, hepsini test et, ve çalışanları bilinen portlar
listesine ekle
    Implies -x, as acc -x -t p
    e.g., acc -t p

  -T|--logtail   accd loglarını görüntüle (tail -F)
    e.g., acc -T

  -u|--upgrade [-c|--changelog] [-f|--force] [-k|--insecure] [-n|--non-interactive]   Online güncelleme/sürüm düşürme
    e.g.,
      acc -u dev (en son versiyona güncelle)
      acc -u (bulunulan (branch)'teki son versiyona güncelle)
      acc -u master^1 -f (bir önceki versiyon)
      acc -u -f dev^2 (iki versiyon öncesi)
      acc -u v2020.4.8-beta --force (güncelleme/sürümü düşürmeyi zorla -> v2020.4.8-beta)
      acc -u -c -n (eğer güncelleme varsa, versiyon numarasını yazdır ve changelog(değişimler) linkini göster)
      acc -u -c (same as above, but with install prompt)

  -U|--uninstall   acc ve AccA 'yı tamamen kaldır
    e.g., acc -U

  -v|--version   acc versiyon ve versiyon kodunu yazdır
    e.g., acc -v

  -w#|--watch#   Bataryada olanları izle/görüntüle
    e.g.,
      acc -w (her 3 saniyede bir güncelle)
      acc -w0.5 (her yarım saniyede bir güncelle)
      acc -w0 (eksta gecikme yok)


Çıkış kodları

  0. Doğru/başaarılı
  1. Yanlış/genel olarak hatalı
  2. Yanlış syntax
  3. Eksik busybox binary
  4. root olarak çalışmıyor
  5. Güncelleme mevcut ("--upgrade")
  6. Güncelleme yok ("--upgrade")
  7. Şarjı devre dışı bırakılamadı.
  8. Daemon zaten çalışıyor ("--daemon start")
  9. Daemon çalışmıyor ("--daemon" and "--daemon stop")
  10. Hiçbir şarj portu çalışmıyor (--test)
  11. 0-9999 aralığından akım (mA)
  12. Başlatma işlemi başarısız
  13. $TMPDIR/acc.lock kitlenemedi
  14. ACC başlatılamadı, çünkü Magisk module 'disable flag' aktif durumda
  15. Idle mod destekleniyor (--test)
  16. Şarj aktif etme işlemi başarısız (--test)

  Loglar ("--log --export") çıkış kodları 7 ve 10'da otomatik olark yazdırılır


Tavsiyeler

  Komutlar kolaylık olması açısından arka arkaya sıralanabilir.
    e.g., 30 dakika şarj et, 6 saat şarj etmeyi durdur, 85% seviyesine kadar şarj et ve daemon yeniden başlat
    acc -e 30m && acc -d 6h && acc -e 85 && accd

  Basit bir profil
    acc -s pc=60 rc=55 mcc=500 mcv=3900
      Şarj seviyesi 55-60% arasında tutulur, akım 500 mA ve voltaj 3900 milivolt ile sınırlanır.
      Gece vakti "sürekli-şarjda" durumları için ideal.

  Bütün bilgiler için acc -r (veya --readme) kodlarını çalıştırın (önerilir)
EOF
}


print_exit() {
  echo "Çıkış"
}

print_choice_prompt() {
  echo "(?) Tercihiniz, [enter]: "
}

print_auto() {
  echo "Otomatik"
}

print_default() {
 echo "Varsayılan"
}

print_curr_restored() {
  echo "Varsayılan maksimum şarj akımı geri yüklendi"
}

print_volt_restored() {
  echo "Varsayılan maksimum şarj voltajı geri yüklendi"
}

print_read_curr() {
  echo "Öncelikle varsayılan maksimum akım değer/değerlerinin okunması lazım"
}

print_curr_set() {
  echo "Maksimum şarj akımı $1$(print_mA) olarak ayarlandı"
}

print_volt_set() {
  echo "Maksimum şarj voltajı $1$(print_mV) olarak ayarlandı"
}

print_wip() {
  echo "Geçersiz opsiyon"
  echo "- Yardım için acc -h veya -r"
}

print_press_key() {
  printf "Devam etmek için herhangi bir tuşa basın..."
}

print_lang() {
  echo "Dil 🌐"
}

print_doc() {
  echo "Kullanım kılavuzu 📘"
}

print_cmds() {
  echo "Bütün komutlar"
}

print_re_start_daemon() {
  echo "daemon başlat/yeniden başlat ▶️ 🔁"
}

print_stop_daemon() {
  echo "daemon durdur ⏹️"
}

print_export_logs() {
  echo "Logları çıkart"
}

print_1shot() {
  echo "Bir kereliğine verilen bir seviyeye kadar şarj et (varsayılan: 100%), kısıtlamalar olmadan"
}

print_charge_once() {
  echo "Bir kereliğine #% seviyesine kadar şarj et"
}

print_mA() {
  echo " Miliamper"
}

print_mV() {
  echo " Milivolt"
}

print_uninstall() {
  echo "Kaldır"
}

print_edit() {
  echo "$1 düzenle"
}

print_flash_zips() {
  echo "zip yükle"
}

print_reset_bs() {
  echo "Batarya istatistiklerini sıfırla"
}

print_test_cs() {
  echo "Şarj portlarını test et"
}

print_update() {
  echo "Güncelleme için kontrol et 🔃"
}

print_W() {
  echo " Watt"
}

print_V() {
  echo " Volt"
}

print_available() {
  echo "$@ uygun durumda"
}

print_install_prompt() {
  printf "- İndirip yüklemeli müyüm ([enter]: evet, CTRL-C: hayır)? "
}

print_no_update() {
  echo "Güncelleme mevcut değil"
}

print_A() {
  echo " Amper"
}

print_only() {
  echo "sadece"
}

print_wait() {
  echo "Bu biraz zaman alabilir... ⏳"
}

print_as_warning() {
  echo "⚠️ DİKKAT: Eğer şarj kablosunu takmazsan batarya ${1}% seviyesinde sistemi kapatacağım!"
}

print_i() {
  echo "Batarya bilgisi"
}

print_undo() {
  echo "Güncellemeyi geri al"
}

print_blacklisted() {
  echo "  Port kara listede; test edilmeyecek 🚫"
}


print_acct_info() {
  echo "
💡Notlar/Tavsiyeler:

  Bazı portlar -- özellikle akım ve voltaj kontrol edenlerde -- dengesizlikler kaçınılmaz. Eğer bir port en az iki kere çalıştıysa, iş gördüğünü
varsayın.

  Sonuçlar farklı koşullara ve güç kaynaklarına göre değişebilir, \"readme > troubleshooting > charging switch\" kısmında da bahsedildiği gibi.

  Bütün portları test mi etmek istiyorsunuz? \"acc -t p\" güç kaynağı loglarından hepsini alıyor (as \"acc -p\"), test ediyor, ve çalışanları bilindik
portlar listesine ekliyor.

  Şarj portlarını test etmek için, acc -ss (asistan) veya acc -s s=\"portlar buraya yazılıyor --\" kodlarını çalıştırın.

  battIdleMode: cihazın yalnızca şarjdan beslenerek çalışıp/çalışamayacağını ifade eder.

  Bu komutun çıktısı /sdcard/Download/acc-t_output.txt dizinine kaydedilir."
}


print_panic() {
  printf "\nDİKKAT: test aşamasında olan bir özellik, dikkat aney!
Bazı sorunlu kontrol dosyaları otomatik olarak kara listeye alındı, bilindik kalıplar kullanılarak.
Test etmeden önce potansiyel portları görmek/düzenlemek istiyor musunuz?
a: operasyondan vazgeç n: hayır | y: evet (varsayılan) "
}
