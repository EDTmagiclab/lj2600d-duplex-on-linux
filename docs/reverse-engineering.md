# 逆向记录：从 Windows 驱动里挖出双面命令

这份文档记录 `rastertobrlaser-duplex` 是怎么做出来的——包括走过的弯路。如果你
想给别的 Brother 机型补功能，思路是通用的。

## 0. 起点

手上只有一份联想的 Windows 驱动安装包（`Lenovo_LJ2600D_Driver_Setup`），以及一台
在 Linux 下能用 brlaser 打单面、但不会双面的 LJ2600D。

目标：搞清楚驱动到底往打印机里写了什么字节，让双面生效。

## 1. 先判断驱动是什么类型

`driver/x64/LENLJB0A.INF` 里出现了 `BRLM03A.DLL`——这是 Brother 的渲染模块。也就是说
这不是一份普通 PCL/PostScript 驱动，而是一个 **GDI 光栅驱动**：Windows 负责把页面
渲染成位图，驱动再压成打印机私有的光栅格式，通过 USB 送出去。

结论很明确：这种驱动不可能在 Linux 上跑。但它同时也提示了正确的方向——这台机器
说的是 Brother 的私有方言，不是标准 PCL。

## 2. DSI 文件里的能力声明

驱动目录里有一批 `.DSI` 配置文本，是明文。`LESL2600D_0000.DSI` 里：

```
DuplexFunction=0x0034
...
TWOSIDED_UNIT
BOOKLET_UNIT
```

`TWOSIDED_UNIT` 直接坐实了硬件有双面单元。而 `DuplexFunction` 的取值和同系列其他
机型不一样（别的机型是 `0x0004`），说明联想对这个型号的双面做了特殊处理——这就是
后来"命令位置很讲究"的伏笔。

## 3. DLL 里没有 `DUPLEX=ON`

把驱动目录下所有二进制过了一遍字符串，最接近的一条是编码 DLL 里的：

```
@PJL SET DXBACKSIDEFIRSTSENDMODE=
```

这是"背面先送"的 PJL 开关，不是双面开关本身。整个驱动里找不到 `@PJL SET DUPLEX=ON`
这类直白的东西。

原因：Windows 侧的双面选择存在 DEVMODE 的 `dmDuplex` 字段里，驱动在运行时把它翻译成
打印机命令——**翻译逻辑在代码里，不在字符串里**。静态分析到这儿基本到头了。

## 4. 决定性的一步：抓真实输出

与其继续猜，不如让驱动自己说。方法：

1. 在 Windows 上把 LJ2600D 驱动装到一个临时的打印队列，端口指向文件；
2. 用**完全相同的两页文档**，只把 DEVMODE 的 `dmDuplex` 分别设成
   `DMDUP_SIMPLEX` / `DMDUP_VERTICAL` / `DMDUP_HORIZONTAL`；
3. 各提交一次，拿到三份原始数据流。

结果非常干净：

| 文件 | `dmDuplex` | 大小 |
|---|---|---|
| `ab_simplex.bin` | `DMDUP_SIMPLEX` | 34836 |
| `ab_duplex.bin` | `DMDUP_VERTICAL`（长边） | 34836 |

**大小完全一样，逐个字节比对只差一个字符**：

```
单面:  ... ESC & l 0 S ...
双面:  ... ESC & l 1 S ...
```

`ESC&l#S` 就是 PCL 的 Simplex/Duplex Print 命令：`0` 单面、`1` 长边、`2` 短边。
到这里，命令找到了。

> 顺带一提：之前一次抓包里两份文件差了 41 字节，那是因为两次打印的页面**内容**不同
> （一份带页码、一份不带），渲染出的光栅数据自然不一样。抓包对比时务必保证内容一致，
> 否则差异会被噪声淹没。

## 5. 弯路一：命令放错位置，一切都白搭

最直觉的实现是"在 brlaser 的输出里插一条 `ESC&l1S`"。于是有了三个变体：

| 变体 | 前导 | 结果 |
|---|---|---|
| V1 | 保留 `ESC E`，补 `ESC&l7H`，双面命令放在 `ESC&l1X` **之前** | 双面 ✅ |
| V2 | 整段换成 Windows 的前导（无 `ESC E`） | 双面 ✅ |
| V3 | Windows 前导但保留 `ESC E` 复位 | 双面 ✅ |

三个都成功，而更早那版把命令插在 `ESC&l1X` **之后**的实现，打印出来是两张单面纸。

结合第 2 节 `DuplexFunction` 的差异，可以给出一个能解释全部现象的模型：

> 这台引擎在处理 `ESC&l1X`（份数）的瞬间锁存页面设置，之后再来的 `ESC&l#S` 被忽略。

所以双面命令必须**在份数命令之前**，并且前面要带一条进纸源命令 `ESC&l7H`
（Windows 驱动每次都发它）。这也顺带解释了第 6 节那个怪现象。

## 6. 弯路二：brlaser 自己就发了一条 `ESC&l2S`

`strings` 看 brlaser 二进制，里面赫然有一条 `&l2S`：

```
@PJL ENTER LANGUAGE = PCL
&l%dX
&l2S          ← 就是这个
```

它紧跟在份数命令后面。按 PCL 字面意思这是"短边双面"，但用原生 brlaser 打印明明
是单面。

用第 5 节的模型一解释就通了：它在 `ESC&l1X` 之后，被忽略了。所以**不要**指望它，
也不要费劲去删它——按正确顺序补一条在前面的就行。

## 7. 弯路三：CUPS 不把 PPD 默认值传给过滤器

PPD 里写好 `*DefaultDuplex: DuplexNoTumble`，`lpadmin -o Duplex=...` 也设了，结果
过滤器收到的 options 字符串里什么都没有，作业依旧按单面走。

两个坑叠在一起：

1. **PPD 里的 `*DefaultDuplex` 只是给客户端看的**，cupsd 不会把它塞进过滤器的参数；
2. 更隐蔽的一个——如果选项被追加在 PPD 的 `*% End of br2140.ppd` 标记**之后**，
   cupsd 解析到那一行就停了，等于整个选项根本不存在，`lpadmin -o` 会静默丢弃。

第二条坑很值得记：往生成的 PPD 里手写选项时，一定要插到结束标记之前。

最终方案是让过滤器自己决定默认值（`/etc/cups/lj2600d-duplex.conf`），不再依赖
CUPS 传递。

## 8. 怎么验证字节没被改坏

不靠"看起来能打"，靠哈希。

搭一个只把数据流写到文件的假后端：

```sh
#!/bin/sh
# /usr/lib/cups/backend/hbcap
if [ $# -eq 0 ]; then
  echo 'file hbcap:/tmp/cap.pcl "CAP" "MFG:Lenovo;MDL:LJ2600D;CMD:HBP;"'
  exit 0
fi
URI="${DEVICE_URI:-$0}"
case "$URI" in
  hbcap:*) cat > "${URI#hbcap:}" ;;
  *)       cat > /tmp/cap.pcl ;;
esac
```

> 这里踩了一个坑，值得单独说：很多文档讲"设备 URI 在后端的 `argv[0]`"，那是给
> 编译型后端讲的。**shell 脚本后端里 `$0` 永远是脚本自己的路径**（内核启动
> `#!/bin/sh` 脚本时会把原始 `argv[0]` 丢掉，换成脚本名），真正的 URI 在
> `DEVICE_URI` 环境变量里。用 `$0` 取 URI 的后果是数据被写到脚本自己身上，或者
> 悄悄落到某个默认路径——而 CUPS 照样报 "backend exited with no errors"，很难
> 察觉。我第一次就是这么写错的，抓了半天以为打印机没收到数据。

然后用同一个队列分别打 `Duplex=None` 和默认双面，把两份输出**去掉 `ESC&l#S` 后**
做 MD5：

```
cap_dup.pcl    body 27975 bytes   md5(...) 一致
cap_none.pcl   body 27968 bytes   md5(...) 一致
```

一致的哈希说明除那一个命令外，光栅数据一个字节都没动。这是"移植"和"重新实现"的
分界线——我们只改前导，绝不去碰图像数据。

## 9. 一个还没完全解释的观察

用 PJL 查询打印机自己的硬件配置：

```
@PJL INFO CONFIG
FEATURES = USB, R600, PAGEP, DLF0, BRNET
```

只报了一个出纸托盘（NORMAL FACEDOWN），**没有报 duplex 单元**。但机器确实能自动
双面（Windows 下验证过，Linux 下现在也验证过）。

也就是说这台机器在 PJL 层面没有如实报告双面能力。这也是为什么一开始"查规格书
和查 PJL 都说不支持"会把人带偏——最终还是要靠实测。

如果将来有人做更完整的支持（比如让 CUPS 自动发现双面能力），这条是需要注意的：
不能只信 `@PJL INFO CONFIG`。

## 复现要点小结

1. 静态分析只能告诉你"驱动是 GDI、硬件有双面单元"，拿不到命令；
2. 抓 Windows 驱动的真实输出，**内容必须一致**，只切一个变量；
3. 差异往往只有一两个字节，但**位置**可能比命令本身更重要；
4. 验证靠哈希，不靠肉眼；
5. CUPS 的坑（PPD 结束标记、默认值不传、后端 `$0` vs `$1`）比打印协议本身更容易
   浪费时间。
