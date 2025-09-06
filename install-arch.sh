#!/bin/bash
set -euo pipefail

echo "=== Arch Linux Dual Boot Installer (существующие разделы) ==="
echo "Используются: /dev/sdb6 (EFI), /dev/sdb7 (swap), /dev/sdb8 (root)"

# --- 1. Проверка интернета ---
if ! ping -c 3 8.8.8.8 &> /dev/null; then
    echo "❌ Нет интернета. Подключитесь (провод или iwctl)."
    exit 1
fi

# --- 2. Проверка разделов ---
if ! lsblk /dev/sdb6 /dev/sdb7 /dev/sdb8 &> /dev/null; then
    echo "❌ Один или несколько разделов не найдены: /dev/sdb6, /dev/sdb7, /dev/sdb8"
    exit 1
fi

# --- 3. Форматирование ---
echo "=== Форматирование разделов ==="
read -p "ВНИМАНИЕ: /dev/sdb8 будет отформатирован. Продолжить? (y/N): " CONFIRM
[[ "$CONFIRM" != "y" ]] && exit 1

# Форматируем только root (оставляем EFI как есть!)
mkswap --label swap /dev/sdb7
swapon /dev/sdb7
mkfs.ext4 -L root /dev/sdb8

# --- 4. Монтирование ---
echo "=== Монтирование разделов ==="
mount /dev/sdb8 /mnt

# Монтируем EFI в /boot (или /boot/efi — зависит от предпочтений)
mkdir -p /mnt/boot
mount /dev/sdb6 /mnt/boot

# Если хочешь монтировать в /boot/efi (более стандартно), используй:
# mkdir -p /mnt/boot/efi
# mount /dev/sdb6 /mnt/boot/efi

# --- 5. Установка базовой системы ---
echo "=== Установка базовой системы ==="
pacstrap -K /mnt base base-devel linux linux-firmware nano vim intel-ucode amd-ucode

# --- 6. Генерация fstab ---
genfstab -U /mnt >> /mnt/etc/fstab
echo "✅ fstab сгенерирован (/dev/sdb6, sdb7, sdb8)"

# --- 7. Chroot и настройка системы ---
cat > /mnt/arch-chroot.sh << 'EOF'
#!/bin/bash
set -euo pipefail

echo "=== Вход в chroot: настройка системы ==="

# --- Часовой пояс ---
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

# --- Локали ---
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
sed -i 's/#ru_RU.UTF-8/ru_RU.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "FONT=cyr-sun16" > /etc/vconsole.conf

# --- Hostname ---
echo "archlinux" > /etc/hostname

# --- Пользователь и пароли ---
read -p "Введите имя пользователя: " USERNAME
useradd -m -G wheel -s /bin/bash "$USERNAME"
passwd
passwd "$USERNAME"

# --- Sudo ---
pacman -S --noconfirm sudo
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# --- NetworkManager ---
pacman -S --noconfirm networkmanager
systemctl enable NetworkManager

# --- rEFInd (загрузчик) ---
echo "=== Установка rEFInd в /dev/sdb6 ==="
pacman -S --noconfirm refind

# Устанавливаем rEFInd в EFI-раздел
refind-install

# --- Настройка refind_linux.conf ---
# Определяем PARTUUID корневого раздела
ROOT_PARTUUID=$(blkid -s PARTUUID -o value /dev/sdb8)

cat > /boot/refind_linux.conf << CONF
"Boot with standard options" "root=PARTUUID=$ROOT_PARTUUID rw add_efi_memmap initrd=\intel-ucode.img initrd=\amd-ucode.img initrd=\initramfs-linux.img"
"Boot with minimal options" "root=PARTUUID=$ROOT_PARTUUID rw"
"Boot to single-user mode" "root=PARTUUID=$ROOT_PARTUUID rw single"
CONF

echo "✅ rEFInd настроен. Будет виден при загрузке."

# --- reflector: быстрые зеркала ---
pacman -S --noconfirm reflector
reflector --country Russia --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
echo "✅ Зеркала обновлены"

# --- Опционально: GNOME ---
echo "Установить GNOME? (y/N)"
read -r INSTALL_GNOME
if [[ "$INSTALL_GNOME" == "y" ]]; then
    pacman -S --noconfirm ttf-dejavu gnome gdm
    systemctl enable gdm
    echo "GNOME установлен. Включите вход через GDM."
fi

# --- Опционально: yay (AUR) ---
echo "Установить yay (AUR помощник)? (y/N)"
read -r INSTALL_YAY
if [[ "$INSTALL_YAY" == "y" ]]; then
    pacman -S --noconfirm git
    cd /tmp
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
    echo "yay установлен. Используйте: yay -S <пакет>"
fi

echo "✅ Настройка завершена. Выход из chroot."
EOF

# Выполняем chroot
chmod +x /mnt/arch-chroot.sh
arch-chroot /mnt ./arch-chroot.sh

# Удаляем временный скрипт
rm /mnt/arch-chroot.sh

# --- 8. Завершение ---
umount -R /mnt
echo "✅ Установка завершена. Перезагрузите: reboot"
echo "rEFInd должен показать Arch и Windows."