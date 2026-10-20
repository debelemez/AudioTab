# AudioTab

GlassTab + AudioHop + ScreenHub tek uygulamada: glassmorphism **⌘Tab / ⌥Tab pencere değiştirici**, **⌘⇧ ile ses çıkışı değiştirici**, **⌘< ile ekran bölme** ve **ekran görüntüsü / MP4 ekran kaydı**. Menü çubuğunda tek ikon durur (o an çalan ses cihazının simgesi).

## Kurulum

Derlemeye gerek yok, son sürümü GitHub'dan kur:

```bash
curl -fsSL https://raw.githubusercontent.com/debelemez/AudioTab/main/install.sh | bash
```

Bundan sonra güncellemeler uygulamanın içinden gelir: yeni sürüm çıkınca menüde **Güncelleme var · Yükle** görünür (Ayarlar › Genel › Güncellemeler'den de denetlenebilir). Uygulama indirir, imzayı doğrular, kendini değiştirir ve yeniden açılır. Ayarlar ve izinler korunur.

Kaynaktan derlemek istersen (Xcode veya Command Line Tools gerekir):

```bash
./build.sh --install
```

## Yeni sürüm yayınlamak

`VERSION` dosyasındaki numarayı artır (ör. `2.3.0`) ve main'e gönder:

```bash
echo 2.3.0 > VERSION
git commit -am "2.3.0" && git push
```

GitHub Actions Mac'te derler (Apple Silicon + Intel), imzalar ve **Releases**'e `AudioTab.zip` koyar. Uygulamalar 6 saat içinde (ya da "Şimdi denetle" ile hemen) yeni sürümü görür.

İmza: Sürümler hep aynı sertifikayla imzalanır (`signing/AudioTab.pem`, özel anahtar repo gizli değişkenlerinde: `CERT_P12`, `CERT_PASSWORD`). macOS izinleri imzaya bağlı olduğu için **güncellemelerden sonra Erişilebilirlik / Ekran Kaydı iznini yeniden vermen gerekmez**. Güncelleyici de sadece bu sertifikayla imzalanmış sürümleri yükler.

Kurulum eski GlassTab ve AudioHop'u kapatır. Ardından `/Applications`'daki **GlassTab.app** ve **AudioHop.app**'i çöpe at; girişte açılıp kısayolları kapmasınlar.

Eski iki uygulamanın ayarları (⌘Tab profilleri, hatırlanan ses cihazları, döngü seçimleri…) ilk açılışta otomatik taşınır.

### İzinler

| İzin | Neden |
|---|---|
| **Erişilebilirlik** | ⌘Tab, ⌥Tab ve ses kısayolu (tek izin hepsine yeter) |
| **Ekran Kaydı** | Pencere önizlemeleri, ekran görüntüsü ve ekran kaydı için |

Sistem Ayarları › Gizlilik ve Güvenlik'ten AudioTab'ı aç. Ekran Kaydı'ndan sonra uygulamayı bir kez kapatıp aç. Yeniden derlemeden sonra izin açık görünüp çalışmıyorsa listeden AudioTab'ı **–** ile kaldırıp tekrar ekle.

Eski AudioHop'un istediği **Giriş İzleme** iznine artık gerek yok.

## Menü ve Ayarlar

Menü kısa: o anki çıkış, cihaza hızlı geçiş, **Ayarlar…** (⌘,) ve Çık.

Ayarlar penceresinde beş sekme var:

- **Ses**
  - Kısayol: ⌘⇧ veya ⌘⇪.
  - Kısayola basınca ne olsun: *Sıradakine geç* veya *Listeyi göster*.
  - ⌘ bırakınca seç, geçiş bildirimi ve Caps Lock ayarları.
  - Cihaz tablosu: her cihaz için *döngüde mi*, *listede mi*. Takılı olmayan cihazları unutma.
  - Uygulamaya göre ses cihazı: atamalar, ekleme/kaldırma.
- **Pencereler:** ⌘Tab ve ⌥Tab için ayrı ayrı: kullan, görünüm (Izgara / Liste), önizlemeler, küçültülmüş pencereler.
  - *Pencereleri her zaman bul*: Kapalı / Tarayıcılar (varsayılan) / Tümü.
- **Ekran:** ekran bölme (aç/kapat, hedef monitör, boşluk), ekran görüntüsü ve kayıt (hepsini kapat, kısayolları tek tek kapat, her biri için kayıt klasörü, video kalitesi).
- **İzinler:** her iznin durumu (verildi / verilmedi), ne için gerektiği ve ayarları açan düğme.
- **Genel:** Girişte başlat.

## Ses kısayolu (⌘⇧)

⌘ basılıyken ⇧'ye **dokunup bırak**. Araya başka bir tuş girerse (⌘⇧4, ⌘⇧Z, ⌘⇧Tab…) hiçbir şey olmaz. ⌘Tab paneli açıkken de tetiklenmez.

**Liste modu** ⌘Tab gibi çalışır:

1. ⌘'yi basılı tut, ⇧ ile cihazlar arasında gez.
2. ⌘'yi bırakınca vurgulu cihaz seçilir.

Panel açıkken:
- ↓ ↑: gezin
- ↩: seç
- 1–9: o sıradaki cihaza direkt geç
- Esc: kapat

**eqMac** listede gösterilmez. Ses eqMac üzerinden giderken de sesin gerçekte hangi cihaza gittiği takip edilir.

## ⌘Tab / ⌥Tab (eski GlassTab)

| Tuş | İş |
|---|---|
| Tab / ⇧Tab | İleri / geri |
| ← → ↑ ↓ | Gezin |
| ⌘'yi bırak, ↩, Space, tıkla | Seçili pencereye geç |
| Esc | İptal |
| W · M · H · Q | Kapat · Küçült · Gizle · Çık |
| Kartta kırmızı nokta | Pencereyi kapat (panel açık kalır) |
| Kartta bölme düğmesi | Pencereyi ekranın bir bölmesine taşı |
| S | Uygulamanın ses cihazını değiştir (yok → cihaz 1 → cihaz 2 → … → yok) |

**Liste görünümü:** Ayarlar › Pencereler › Görünüm › *Liste* seçilirse ⌘Tab, ses listesi gibi alt alta satırlar gösterir: büyük ikon, pencere başlığı, uygulama adı ve atanmış ses cihazı. Uzun listelerde seçim ilerledikçe liste kayar.

## Ekranı böl (⌘<)

1. **⌘<**'ye bas (Türkçe klavyede sol ⇧'nin yanındaki tuş). Birden fazla monitör varsa hedef farenin olduğu monitördür; her monitörde büyük bir numara çıkar. **Tab** ya da tekrar **⌘<** hedefi değiştirir. Ayarlardan "Her seferinde sor" seçilirse önce monitör sorulur.
2. Düzeni seç (1–9): tam ekran, 2 dikey, 2 yatay, 3 dikey, ⅓+⅔, ⅔+⅓, ½+¼¼, 2×2, 3×2.
3. Bölmeler sırayla vurgulanır. Her biri için listeden pencereyi seç (↑↓ ve ↩, tıklama ya da 1–9). Space bölmeyi boş bırakır, ⌘↩ hemen uygular. Son bölmeden sonra pencereler yerleşir.

⌘Tab kartındaki **bölme düğmesi** (kırmızı noktanın sağı) aynı işi tek pencere için yapar: düzenlerden birinde bir bölmeye tıkla, pencere oraya taşınır. Monitör seçimi orada da var.

Not: Açıkken macOS'un ⌘< kısayolu (aynı uygulamanın pencereleri arasında geçiş) kapanır. Ayarlardan ekran bölmeyi kapatınca geri gelir.

## Ekran görüntüsü ve kayıt

| Kısayol | Ne yapar |
|---|---|
| ⌘⇧3 | Sadece **farenin olduğu monitörün** görüntüsü |
| ⌘⇧4 | Alan seçimi (macOS'un seçicisi; Space ile pencere) |
| ⌘⇧6 | **Kaydırmalı görüntü**: alanı seç, sayfa kendiliğinden kayar ve tek uzun PNG olur. Esc ile erken bitir. Sabit üst/alt çubuklar tekrar etmez. macOS 14+. |
| ⌘⇧5 | Çekim paleti: bu monitör · alan · kaydırmalı · **monitörü kaydet** · **alanı kaydet**. Kayıt sürerken ⌘⇧5 kaydı durdurur. |

- Video **MP4 / H.264** olarak kaydedilir. *Yüksek* ayarında 1440p60 için yaklaşık 31 Mbit/sn, *En yüksek* ayarında yaklaşık 55 Mbit/sn. 30/60 fps, sistem sesi ve imleç isteğe bağlı.
- Kayıt sırasında sağ üstte **kırmızı nokta ve süre** görünür. Sadece sen görürsün, kayda girmez. Tıklayınca kayıt durur. Menü çubuğu ikonu da kırmızı kayıt simgesine döner.
- Her tür için ayrı kayıt klasörü seçilebilir (varsayılan Masaüstü). İstersen görüntüler panoya da kopyalanır.
- Ayarlar › Ekran › *Kullan* kapatılınca hepsi devre dışı kalır ve macOS'un kendi ⌘⇧3/4/5 kısayolları geri gelir. Kısayollar tek tek de kapatılabilir.
- macOS 15 ve sonrası, ekran kaydı yapan uygulamalar için arada bir onay sorabilir. Bu sistemin kendi uyarısıdır.

## Pencereleri her zaman bul (Chrome profilleri)

macOS'un pencere listesi sadece o an bulunduğun masaüstündeki pencereleri verir. Chrome yoğunken bu listeyi geç de verebilir. Bu yüzden başka profilin arkadaki penceresi, başka masaüstündeki ya da tam ekrandaki bir pencere bazen ⌘Tab'da görünmüyordu.

AudioTab artık tarayıcıların tüm pencerelerini arka planda bir kayıtta tutuyor. ⌘Tab'a basınca canlı liste ile bu kayıt birleşiyor; Chrome geç cevap verse bile tüm pencereler listede oluyor. Diğer masaüstündeki bir pencereyi seçince macOS o masaüstüne geçer.

- Kayıt sadece bir şey olunca güncelleniyor: masaüstü değişince, tarayıcı açılınca veya öne gelince (aynı uygulama için en fazla 5 saniyede bir). Timer ya da sürekli tarama yok.
- Ayarlar › Pencereler › *Pencereleri her zaman bul*: **Tarayıcılar** varsayılan. Chrome, Brave, Edge, Arc, Safari, Firefox, Vivaldi, Opera ve Zen dahil. **Tümü** seçilirse her uygulama için yapılır.

## Uygulamaya göre ses cihazı

Bir uygulamaya ses cihazı atarsan, o uygulama öne geldiğinde (⌘Tab, tıklama, Dock fark etmez) ses otomatik o cihaza geçer. Örnek: Spotify → hoparlör, Discord → kulaklık. Atanmamış uygulamalarda ses olduğu yerde kalır.

- Atamak için ⌘Tab açıkken **S**'ye bas ya da Ayarlar › Ses › *Uygulamaya göre ses cihazı*'nı kullan.
- Atanan cihaz ⌘Tab kartında küçük bir rozet olarak görünür.
- macOS'ta ses çıkışı sistem genelindedir. Cihaz değişince arka planda çalan diğer uygulamaların sesi de yeni cihaza gider.

Bu sürümde kartlar daha belirgin ve panel daha hızlı:
- Uygulama ikonları ve adları büyüdü.
- Pencereler tüm uygulamalarda aynı anda taranıyor; yavaş cevap veren bir uygulama diğerlerini bekletmiyor.
- Panel önceden hazırlanıyor ve animasyonsuz, anında açılıyor.
- Panelin arkası koyulaştırıldı.
- Önizlemeler daha büyük.
- Her kartın kendi cam zemini var.
- Seçili kart vurgu renginde kalın çerçeve ve ışımayla öne çıkıyor.
- Fare kartın dışına çıkınca seçim artık kaybolmuyor.

## Pil

Boştayken timer ya da polling yok; uygulama sadece klavye olaylarını bekler. Pencere listesi ve önizlemeler yalnızca ⌘Tab basılıyken alınır. Ses cihazı değişikliklerini CoreAudio bildirir, uygulama sorgulamaz.
