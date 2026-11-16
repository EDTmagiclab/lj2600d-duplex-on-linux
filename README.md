# lj2600d-duplex-on-linux

给 **Lenovo LJ2600D**（以及同引擎的 Brother HBP 机型）在 Linux/CUPS 下补上**自动双面打印**。

A CUPS filter that adds automatic two-sided printing to the open-source
`brlaser` driver for the Lenovo LJ2600D — a Brother HBP engine that brlaser
prints fine but cannot duplex.

---

## 为什么需要这个东西

联想只为 LJ2600D 提供 Windows 驱动，而且那是个 Brother 衍生的 GDI 光栅驱动
（驱动目录里的 `BRLM03A.DLL` 就是 Brother 的渲染模块），Linux 无法直接使用。

Linux 下的正解是开源驱动 **brlaser**——它输出的正是这台机器要的 Brother HBP
光栅协议，打单面完全正常。问题是 brlaser 从头到尾不发 PCL 双面命令，所以
CUPS 里根本没有"双面"这个选项。

这个仓库做的事情就一件：在 brlaser 输出的字节流里，把双面命令补到**唯一能被
这台引擎接受的位置**上。

## 测试环境

| | |
|---|---|
| 打印机 | Lenovo LJ2600D（USB，`usb://Lenovo/LJ2600D`） |
| 系统 | Ubuntu 22.04 |
| CUPS | 2.4.1 |
| brlaser | 6（`printer-driver-brlaser`） |

凡是 `1284DeviceID` 里带 `CMD:PJL,HBP`、且装有物理双面单元的 Brother 机型
理论上都适用（双面命令是 PCL 标准的 `ESC&l#S`）。仓库里的
`driver/lj2600d-duplex.drv` 额外提供了一个 HL-2140 条目——LJ2600D 就是那台
机器的 OEM 版本。

## 安装

```bash
sudo apt install printer-driver-brlaser python3

git clone https://github.com/EDTmagiclab/lj2600d-duplex-on-linux.git
cd lj2600d-duplex-on-linux
sudo bash install.sh
```

`install.sh` 会：装过滤器 → 装驱动定义 → 写默认设置 → 重启 CUPS → 自动探测
USB 设备并建队列（默认队列名 `LJ2600D`，A4，开启共享）。

常用参数：

```bash
sudo bash install.sh --queue Office            # 换个队列名
sudo bash install.sh --default simplex         # 默认单面，需要时再选双面
sudo bash install.sh --model HL-2140           # 真·HL-2140 用这个条目
sudo bash install.sh --device usb://Lenovo/LJ2600D
sudo bash install.sh --no-queue                # 只装驱动，不动打印队列
```

> 从 Git 仓库 clone 下来时脚本可能没有可执行位，所以上面用 `bash install.sh`；
> 也可以先 `chmod +x install.sh uninstall.sh`。

## 使用

装好之后**默认就是双面**（长边翻转），任何客户端不改设置直接打就是双面。

| 需求 | 做法 |
|---|---|
| 双面，长边翻转（默认） | 什么都不用做 |
| 双面，短边翻转（横向翻页） | `lp -d LJ2600D -o Duplex=DuplexTumble FILE` |
| 单面 | `lp -d LJ2600D -o Duplex=None FILE` |
| 改默认值 | 编辑 `/etc/cups/lj2600d-duplex.conf` |

配置文件只有一行：

```ini
default = duplex-long-edge     # 或 duplex-short-edge / simplex
```

CUPS 不会把 PPD 里的 `*DefaultDuplex` 传给过滤器，所以默认值得由过滤器自己读，
这个文件就是干这个的。

客户端侧（Windows / macOS / 手机）走标准 IPP：打印对话框里选"双面"会以
`sides=two-sided-long-edge` 传过来，过滤器两种写法都认：

```bash
# 这些等价
lp -d LJ2600D -o Duplex=DuplexNoTumble FILE
lp -d LJ2600D -o sides=two-sided-long-edge FILE
```

## 工作原理

brlaser 每个作业只发一次这样的前导，后面全是光栅数据：

```
ESC E   ESC&l1X   ESC&l2S   [光栅...]
        ↑份数     ↑双面？
```

联想 Windows 驱动在双面时，把双面命令放在份数命令**之前**，并且不发 `ESC E`
复位。抓两份输出（同一文档，只切单面/双面）对比，整个数据流只差一个字符：

```
单面:  ESC&l0S
双面:  ESC&l1S
```

关键在于位置。实测这台引擎是在处理 `ESC&l1X` 的瞬间锁存双面状态的：

```
ESC&l7H   ESC&l1S   ESC&l1X   ← 双面生效
ESC&l1X   ESC&l1S             ← 双面无效，还是单面
```

顺带解释了 brlaser 末尾那个 `ESC&l2S` 为什么没让打印机双面——它在份数命令之后，
被忽略了。

所以过滤器做的事就是把这个前导改写成：

```
ESC&l7H   ESC&l<1|2>S   ESC&l<copies>X
```

其余字节原样透传（含全部光栅数据，一个字节都没动）。

想了解完整的逆向过程——怎么从 DSI 文件、驱动 DLL、Windows 打印队列里一层层
挖出这条命令的——见 [`docs/reverse-engineering.md`](docs/reverse-engineering.md)。

## 验证

- **字节层面**：同一份两页文档分别抓包，新旧两条路径的输出（归一化作业名后）**逐字节
  完全一致**；去掉 `ESC&l#S` 后 MD5 也一致——除了这一个命令，其他字节零改动。
- **选项矩阵**：默认 / `Duplex=None` / `Duplex=DuplexTumble` / `sides=one-sided` /
  配置文件切 `simplex`，五种情况都核对了双面命令的取值和所在位置。
- **实物层面**：两页测试页打成一张纸的正反两面，方向正确。

装好之后 `lpoptions -p LJ2600D -l` 里能看到：

```
Duplex/2-Sided Printing: None *DuplexNoTumble DuplexTumble
```

带星号的就是当前默认值。

## 文件说明

```
install.sh                                 安装脚本
uninstall.sh                               卸载脚本
filters/rastertobrlaser-duplex             过滤器本体（Python 3）
driver/lj2600d-duplex.drv                  CUPS 驱动定义（基于 brlaser 的 drv）
docs/reverse-engineering.md                逆向记录
```

## 排错

**打出来是白纸**
说明队列用的不是 brlaser 而是标准 PCL 驱动（如 `laserjet.ppd`）。这台机器不认
HP PCL5e 光栅，只认 Brother HBP。检查：

```bash
grep cupsFilter /etc/cups/ppd/LJ2600D.ppd
# 应该是 rastertobrlaser-duplex，不能是 rastertopclx / pcl5
```

**内容是单面，但选项设了双面**

```bash
grep -i "prologue not recognised" /var/log/cups/error_log
```

出现这行说明 brlaser 的输出格式变了（升级过 brlaser？），过滤器没找到前导，于是
原样透传。可以先用 `cupsfilter` 把前导打出来对照。

**Filter failed**

```bash
tail -50 /var/log/cups/error_log
```

最常见的两个原因：`/usr/lib/cups/filter/rastertobrlaser` 不存在（没装
brlaser），或者过滤器没有可执行位。

**打印机型号对但没双面**

确认机器真的装了物理双面单元。不带 `D` 后缀的机型（如 LJ2600）是手动双面，
发双面命令不会有任何效果。

## 许可

GPL-2.0-or-later。过滤器链接并调用 GPL 的 brlaser，`driver/lj2600d-duplex.drv`
派生自 brlaser 的驱动定义文件。

## 致谢

- [brlaser](https://github.com/pdewacht/brlaser) — Peter De Wachter，没有它这台
  机器在 Linux 下根本打不了字
- CUPS 项目
