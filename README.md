# 🚀 CCB应用镜像源 🚀

### 🌟 关于这个镜像仓库 🌟

这个仓库是储存CCB原创脚本以及多个实用脚本的**镜像和改良版**以及其他一些应用。我创建它的主要目的是：

#### 对于CCB脚本

-  **实际使用**：填充大众脚本所缺少的(我缺的营养这一块)
-  **小众专项**：部分服务器需要包括但不限于: 策略路由/一键修复等功能

#### 对于镜像脚本

-   **优化体验**：针对CN服务器的使用环境进行"特别优化"
-   **修复 BUG**：修正原版脚本中可能存在的一些小问题
-   **历史遗留**：原脚本作者可能已经废弃脚本
-   **保持纯净**：作为一份可靠的备份，防止在极端情况下,原脚本未来可能出现的意外"污染"

我们会对脚本进行持续的维护和改进，在此特别感谢原作者们的辛勤付出！

---

### 📁 目录结构

```
src/
├── original/          # CCB 原创脚本
│   └── leikwan_9929_route.sh
└── optimized/         # 优化改良脚本
    ├── gost.sh
    └── net_tools.sh
```

---

### 🧰 脚本列表

#### 🔥 CCB 原创脚本

-   [`leikwan_9929_route.sh`](#leikwan路由) - 双线服务器路由（leikwan双网卡服务器专享）

#### ⚡ 优化改良脚本

-   [`gost.sh`](#gost隧道) - 全能Gost网络隧道
-   [`net_tools.sh`](#系统优化) - 服务器性能一键优化

---

## `leikwan_9929_route.sh` - 双线服务器路由魔术师 🎩

### leikwan路由

**🔖 CCB 原创脚本**

如果你有台"双网卡路由"服务器（比如同时有 CN2 和 9929 线路），这个脚本就是为你量身定做的！再也不用手动敲 `ip route` 命令了。

**🚁 一键梭哈命令**
```bash
wget --no-check-certificate -O leikwan_9929_route.sh https://github.com/zhongyizhu11-jpg/mirror/raw/main/src/original/leikwan_9929_route.sh && chmod +x leikwan_9929_route.sh && ./leikwan_9929_route.sh
```

**用它能干啥？**

-   **线路切换自如**: 想让某个 IP 走 9929，另一个走 CN2？没问题，指定一下就好。
-   **智能测速**: 不确定哪条线更快？让脚本跑个分，它会告诉你到某个IP哪条线延迟更低。
-   **路由持久化**: 设置好的路由规则，重启服务器也不会丢，还能设置开机自动加载。

**怎么用？**

1.  先打开脚本，把顶部的网络配置改成你自己的IP和网卡名。
    ```bash
    # 改成你自己的信息
    CN2_IF="eth1"
    CN2_GW="10.8.0.1"
    # ...等等
    ```
2.  跑起来！
    ```bash
    bash leikwan_9929_route.sh
    ```

**友情提示**: 这脚本是为特定服务商(leikwanhost)定制的，改改也能在自己的服务器上用。

---

## `gost.sh` - 你的全能网络隧道专家 🧙‍♂️

### gost隧道

**🔖 优化脚本** - 本脚本 fork 自 [KANIKIG/Multi-EasyGost](https://github.com/KANIKIG/Multi-EasyGost)，并在此基础上进行了优化和修改。

还在为复杂的网络隧道配置头疼？`gost` 本身就是个神器，这个脚本更是让神器用起来得心应手。

**🚁 一键梭哈命令**
```bash
wget --no-check-certificate -O gost.sh https://github.com/chunkburst/mirror/raw/main/src/optimized/gost.sh && chmod +x gost.sh && ./gost.sh
```

**用它能干啥？**

-   **秒速安装/更新**: 一键All in one，放弃大脑
-   **直接转发**: 普通 TCP/UDP 流量转发，简单直接。

---

## `net_tools.sh` - 服务器性能一键优化 ⚡️

### 系统优化

**🔖 优化脚本** - 本脚本源自 **NNC.SH** 的作品，我们对其进行了镜像和适配。

新开的服务器感觉网络卡卡的？用这个脚本给它打一针"鸡血"！集合了各种常用的 Linux 系统优化，让你的小鸡变雄鹰。

**🚁 一键梭哈命令**
```bash
wget --no-check-certificate -O net_tools.sh https://github.com/chunkburst/mirror/raw/main/src/optimized/net_tools.sh && chmod +x net_tools.sh && ./net_tools.sh
```

**用它能干啥？**

-   **BBR 一键上车**: 如果你的内核太老，一键给你换上最新的 BBR 原版内核。
-   **TCP 优化**: 自动调整一堆 TCP 参数，让网络传输更丝滑。
-   **开启转发**: 做中转？一键开启内核转发。
-   **解除封印**: 调高系统资源限制，高并发应用跑起来更安心。
-   **隐身术**: 不想让别人 Ping 到你的服务器？一键屏蔽。想开了再一键取消。
