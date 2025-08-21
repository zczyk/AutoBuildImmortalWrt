#!/bin/sh
# 99-custom.sh 就是immortalwrt固件首次启动时运行的脚本 位于固件内的/etc/uci-defaults/99-custom.sh
# Log file for debugging
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE
# 设置默认防火墙规则，方便单网口虚拟机首次访问 WebUI 
# 因为本项目中 单网口模式是dhcp模式 直接就能上网并且访问web界面 避免新手每次都要修改/etc/config/network中的静态ip
# 当你刷机运行后 都调整好了 你完全可以在web页面自行关闭 wan口防火墙的入站数据
# 具体操作方法：网络——防火墙 在wan的入站数据 下拉选项里选择 拒绝 保存并应用即可。
uci set firewall.@zone[1].input='ACCEPT'

# 设置主机名映射，解决安卓原生 TV 无法联网的问题
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

# 检查配置文件pppoe-settings是否存在 该文件由build.sh动态生成
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "PPPoE settings file not found. Skipping." >>$LOGFILE
    enable_pppoe="no"
else
    # 读取pppoe信息($enable_pppoe、$pppoe_account、$pppoe_password)
    . "$SETTINGS_FILE"
fi

# 检查USB设置文件
USB_SETTINGS_FILE="/etc/config/usb-net-settings"
usb_mode="lan"  # 默认lan，适合纯USB
if [ -f "$USB_SETTINGS_FILE" ]; then
    . "$USB_SETTINGS_FILE"
fi
echo "USB mode: $usb_mode" >>$LOGFILE

# 计算网卡数量
count=0
ifnames=""
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
        count=$((count + 1))
        ifnames="$ifnames $iface_name"
    fi
done
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')

# 网络设置（兼容纯USB：如果count小，统一lan桥接）
if [ "$count" -le 2 ]; then
    # 纯USB或少网卡：删除wan/wan6，统一lan静态
    uci delete network.wan  # 避免多WAN冲突
    uci delete network.wan6
    uci set network.lan.proto='static'
    IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
    if [ -f "$IP_VALUE_FILE" ]; then
        CUSTOM_IP=$(cat "$IP_VALUE_FILE")
        uci set network.lan.ipaddr="$CUSTOM_IP"
        echo "Custom LAN IP: $CUSTOM_IP" >>$LOGFILE
    else
        uci set network.lan.ipaddr='192.168.100.1'
        echo "Default LAN IP: 192.168.100.1" >>$LOGFILE
    fi
    uci set network.lan.netmask='255.255.255.0'
    # 添加所有接口到lan桥接
    section=$(uci show network | awk -F '[.=]' '/\.@?device```math
\d+```\.name=.br-lan.$/ {print $2; exit}')
    if [ -z "$section" ]; then
        echo "Error: br-lan section not found." >>$LOGFILE
    else
        uci -q delete "network.$section.ports"
        for port in $ifnames; do
            uci add_list "network.$section.ports"="$port"
        done
        echo "Added ports to br-lan: $ifnames" >>$LOGFILE
    fi
    uci commit network
else
    # 原多网卡逻辑
    wan_ifname=$(echo "$ifnames" | awk '{print $1}')
    lan_ifnames=$(echo "$ifnames" | cut -d ' ' -f2-)
    uci set network.wan=interface
    uci set network.wan.device="$wan_ifname"
    uci set network.wan.proto='dhcp'
    uci set network.wan6=interface
    uci set network.wan6.device="$wan_ifname"
    section=$(uci show network | awk -F '[.=]' '/\.@?device```math
\d+```\.name=.br-lan.$/ {print $2; exit}')
    if [ -z "$section" ]; then
        echo "error：cannot find device 'br-lan'." >>$LOGFILE
    else
        uci -q delete "network.$section.ports"
        for port in $lan_ifnames; do
            uci add_list "network.$section.ports"="$port"
        done
        echo "ports of device 'br-lan' are update." >>$LOGFILE
    fi
    uci set network.lan.proto='static'
    uci set network.lan.netmask='255.255.255.0'
    IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
    if [ -f "$IP_VALUE_FILE" ]; then
        CUSTOM_IP=$(cat "$IP_VALUE_FILE")
        uci set network.lan.ipaddr="$CUSTOM_IP"
    else
        uci set network.lan.ipaddr='192.168.100.1'
    fi
    uci commit network
fi

# PPPoE设置（如果启用，应用到第一个接口或根据usb_mode调整）
if [ "$enable_pppoe" = "yes" ]; then
    echo "PPPoE is enabled at $(date)" >>$LOGFILE
    first_ifname=$(echo "$ifnames" | awk '{print $1}')
    uci set network.wan=interface
    uci set network.wan.device="$first_ifname"
    uci set network.wan.proto='pppoe'
    uci set network.wan.username="$pppoe_account"
    uci set network.wan.password="$pppoe_password"
    uci set network.wan.peerdns='1'
    uci set network.wan.auto='1'
    uci set network.wan6.proto='none'
    uci commit network
    echo "PPPoE configuration completed on $first_ifname." >>$LOGFILE
else
    echo "PPPoE is not enabled. Skipping configuration." >>$LOGFILE
fi

# 新增：动态检测和配置所有USB网卡（首次启动时处理已插入的）
echo "Detecting all USB Ethernet adapters..." >>$LOGFILE
sleep 10  # 等待USB驱动加载（可根据需要调整）

# 常见USB网卡驱动列表（可扩展）
USB_DRIVERS="ax88179_178a asix r8152 cdc_ether usbnet ax88772 rtl8150"

# 扫描所有eth/en接口，查找USB网卡
usb_eth_list=""
counter=1
for iface in /sys/class/net/eth* /sys/class/net/en*; do
    if [ -d "$iface" ]; then
        iface_name=$(basename "$iface")
        
        # 检查驱动（从uevent文件）
        driver=$(grep DRIVER "$iface/uevent" | cut -d= -f2)
        
        # 如果驱动在USB_DRIVERS列表中，且路径包含"usb"（确认是USB设备）
        if echo "$USB_DRIVERS" | grep -q "$driver" && readlink -f "$iface/device" | grep -q "/usb"; then
            # 防重复：如果已配置，跳过
            if uci get network.$iface_name >/dev/null 2>&1; then continue; fi
            usb_eth_list="$usb_eth_list $iface_name"
            echo "Detected USB Ethernet: $iface_name (driver: $driver)" >>$LOGFILE
        fi
    fi
done

# 如果找到USB网卡，配置它们
if [ -n "$usb_eth_list" ]; then
    for usb_eth in $usb_eth_list; do
        usbwan_name="usbwan$counter"  # e.g., usbwan1, usbwan2 for multiple
        echo "Configuring USB Ethernet $usb_eth as $usbwan_name..." >>$LOGFILE
        
        # 配置为额外WAN口，默认DHCP
        uci set network.$usbwan_name=interface
        uci set network.$usbwan_name.device="$usb_eth"
        uci set network.$usbwan_name.proto='dhcp'
        
        # 如果PPPoE启用，也应用
        if [ "$enable_pppoe" = "yes" ]; then
            uci set network.$usbwan_name.proto='pppoe'
            uci set network.$usbwan_name.username="$pppoe_account"
            uci set network.$usbwan_name.password="$pppoe_password"
            uci set network.$usbwan_name.peerdns='1'
            uci set network.$usbwan_name.auto='1'
            echo "Applied PPPoE to $usbwan_name." >>$LOGFILE
        fi
        
        # 添加到防火墙wan区
        uci add_list firewall.@zone[1].network="$usbwan_name"
        
        counter=$((counter + 1))
    done
    
    uci commit network
    uci commit firewall
    echo "All USB Ethernet adapters configured." >>$LOGFILE
else
    echo "No USB Ethernet adapters detected." >>$LOGFILE
fi

# 若安装了dockerd 则设置docker的防火墙规则
# 扩大docker涵盖的子网范围 '172.16.0.0/12'
# 方便各类docker容器的端口顺利通过防火墙 
if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，正在配置防火墙规则..."
    FW_FILE="/etc/config/firewall"

    # 删除所有名为 docker 的 zone
    uci delete firewall.docker

    # 先获取所有 forwarding 索引，倒序排列删除
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        echo "Checking forwarding index $idx: src=$src dest=$dest"
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            echo "Deleting forwarding @forwarding[$idx]"
            uci delete firewall.@forwarding[$idx]
        fi
    done
    # 提交删除
    uci commit firewall
    # 追加新的 zone + forwarding 配置
    cat <<EOF >>"$FW_FILE"

config zone 'docker'
  option input 'ACCEPT'
  option output 'ACCEPT'
  option forward 'ACCEPT'
  option name 'docker'
  list subnet '172.16.0.0/12'

config forwarding
  option src 'docker'
  option dest 'lan'

config forwarding
  option src 'docker'
  option dest 'wan'

config forwarding
  option src 'lan'
  option dest 'docker'
EOF

else
    echo "未检测到 Docker，跳过防火墙配置。"
fi

# 设置所有网口可访问网页终端
uci delete ttyd.@ttyd[0].interface

# 设置所有网口可连接 SSH
uci set dropbear.@dropbear[0].Interface=''
uci commit

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by wukongdaily"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

# 若luci-app-advancedplus (进阶设置)已安装 则去除zsh的调用 防止命令行报 /usb/bin/zsh: not found的提示
if opkg list-installed | grep -q '^luci-app-advancedplus '; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
    sed -i '/\/usr\/bin\/zsh/d' /etc/init.d/advancedplus
fi

exit 0
