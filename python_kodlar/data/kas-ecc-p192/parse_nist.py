import json
import sys
from pathlib import Path

def pad_hex(val_str):
    """
    Hexadecimal stringi Verilog'un okuyabilmesi için 256-bit'e (64 karaktere) hizalar.
    Olası boşlukları temizler.
    """
    if not val_str:
        return "0" * 64
    return str(val_str).strip().zfill(64)

def main():
    # 1. Scriptin çalıştığı klasörün tam yolunu (Absolute Path) otomatik bul
    # Bu sayede kodu terminalden nereden çalıştırırsanız çalıştırın dosya bulunur.
    script_dir = Path(__file__).resolve().parent

    input_filename = 'internalProjection.json'
    output_filename = 'nist_test_vectors.txt'

    input_path = script_dir / input_filename
    output_path = script_dir / output_filename

    # 2. Dosyanın var olup olmadığını kontrol et
    if not input_path.exists():
        print(f"[HATA] Dosya bulunamadı: '{input_path}'")
        print("Lütfen JSON dosyasının bu Python scripti ile TAM OLARAK aynı klasörde olduğundan emin olun.")
        sys.exit(1)

    print(f"[{input_filename}] okunuyor...")

    # 3. JSON dosyasını güvenli bir şekilde oku
    try:
        with open(input_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"[HATA] JSON formatı bozuk veya hatalı: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"[HATA] Dosya okunurken beklenmeyen bir hata oluştu: {e}")
        sys.exit(1)

    # 4. Verileri ayrıştır ve TXT'ye yaz
    count = 0
    try:
        with open(output_path, 'w', encoding='utf-8') as out:
            test_groups = data.get('testGroups', [])

            for group in test_groups:
                # Sadece P-192 testlerini filtrele
                if group.get('curve') == 'P-192':
                    for test in group.get('tests', []):
                        tcId = test.get('tcId')
                        d    = test.get('privateIut')       # Bizim özel anahtarımız
                        qx   = test.get('publicServerX')    # Karşı tarafın açık anahtarı X
                        qy   = test.get('publicServerY')    # Karşı tarafın açık anahtarı Y
                        z    = test.get('z')                # Beklenen Ortak Sır (Affine X)

                        # Veriler eksiksiz ise yaz
                        if d and qx and qy and z:
                            line = f"{tcId} {pad_hex(d)} {pad_hex(qx)} {pad_hex(qy)} {pad_hex(z)}\n"
                            out.write(line)
                            count += 1

        print(f"\n[BAŞARILI] Toplam {count} adet P-192 test vektörü ayrıştırıldı.")
        print(f"[KAYDEDİLDİ] Dosya konumu: {output_path}")

    except Exception as e:
        print(f"[HATA] Çıktı dosyası yazılırken hata oluştu: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
