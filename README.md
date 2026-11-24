# 把 CapCut 的静默更新按死：一次真实的取证与封锁记录

> 一台 Windows 机器、一个旧版剪映国际版（CapCut 3.6.0.1318）、一次被偷偷替换成 9.8.0.4213 的事故。
> 这篇记录三件事：它是怎么在后台把版本换掉的、我是怎么把它抓现行的、以及最后用什么手段把它彻底按住。
>
> 为什么非要留在旧版：**3.8 及以下是最后一批支持免费字幕识别的版本，4.0 之后开始封堵。**

---

## 一、先看清结构：它不是"一个程序"，是三层

很多人以为剪映就是一个 `CapCut.exe`，所以删掉更新器、改个配置就能停更。实际上这几层分工明确：

```
D:\CapCut\CapCut\CapCut.exe              1.5 MB    启动器（JianyingLauncher）
D:\CapCut\CapCut\uninst.exe              1.7 MB    卸载器
D:\CapCut\CapCut\Configure.ini           38 B      记录"上次运行的是哪个版本"
D:\CapCut\CapCut\ProductInfo.xml        368 B      安装包元信息（appver / full_appver / cid）
D:\CapCut\CapCut\3.6.0.1318\CapCut.exe   0.2 MB    真正的主程序（界面、剪辑、字幕识别都在这里）
D:\CapCut\CapCut\3.6.0.1318\update.exe   0.25 MB   更新执行器：解压、落盘、替换
```

启动器里有明文字符串 `slient_install`、`install_path`，PDB 路径写着：

```
C:\app\cc\LVInstaller\VideofusionInstaller\build\CC_RELEASE\JianyingLauncher.pdb
```

也就是说，**静默安装是它设计里就有的能力**，不是 bug。配置读写在启动器里，主程序和 `update.exe` 反而不含那些键名——这一点用字符串比对就能验证。

---

## 二、它到底怎么完成"强制更新"的

为了看清流程，我做了一次受控实验：先把本地更新开关全部打开（`enableAutoUpdate=true`、`totalSilentUpgradeSwitch=true`、`debugSilentUpgradeSwitch=true`、`upgradeIntervalMin=1`），然后正常启动软件、正常剪视频，全程监控。

**这里有个非常关键的细节：光把开关打开，它并不会立刻下载。**

- 16:39 启动、16:44–17:09 期间网卡只有 **0.5–2 MB/s** 的零散流量，日志里没有任何大文件落盘，也没有 `update.exe` 出现；
- 真正开始拉包，是在**重装了一遍 3.6.0.1318 的安装包、再启动启动器之后**（版本目录里的文件 mtime 变成 17:34）；
- 从 17:34 到 17:42:44，8 分钟内以 **4–5 MB/s** 把约 1.8 GB 拉完并解压。

也就是说：**开关的 `true` 只是"允许"，触发点是一次"安装/启动后的检查"**。全新安装后的元信息（`ProductInfo.xml` 只写了 cid、没有 `appver`）会让启动器判定"需要检查/修复"，于是立刻进入下载流程。

实测到的完整链条：

| 阶段 | 发生了什么 | 观测证据 |
|---|---|---|
| ① 启动 | 启动器读 `Configure.ini` / `ProductInfo.xml`，向服务端查版本 | DNS 里出现 `capcutapi.com`、`capcutstatic.com` 一批域名 |
| ② 下载 | **重装并重新启动后**，后台以 **4–5 MB/s** 持续拉包，总量约 1.8 GB，耗时约 8 分钟 | 网卡持续跑量，而 CapCut 进程**磁盘写入只有 1 KB/s**（典型流式：读进内存不落盘） |
| ③ 解压 | 17:42:44 调用 `3.6.0.1318\update.exe`，7z 直接解压 | 抓到 `update.exe` 进程**写盘峰值 74 MB/s** |
| ④ 落盘 | 生成 `9.8.0.4213` 目录 **1,821 MB**，替换根目录 `CapCut.exe`（1.5 MB → 4.97 MB）与 `uninst.exe`，改写 `ProductInfo.xml`（`appver=9.8.0`）和 `Configure.ini`（`last_version=9.8.0.4213`） | 文件大小、版本资源、ini 内容全部变了 |
| ⑤ 收尾 | 退出/重启的间隙，启动 9.8，**直接删除整个 `3.6.0.1318` 目录（1,263 MB）**，并把 `last_version` 清空 | 重启后目录消失、回收站文件数 = 0（程序直删，不进回收站） |

这里最狠的是第⑤步：它不在你操作时动手，而是在**你退出软件、重启电脑那十几秒**里完成替换和删除。等你回来，旧版已经没了，连回收站都没留。

---

## 三、取证：怎么把它抓现行

这套方法可以复用到任何"偷偷下载/偷偷安装"的软件。

### 1. 先看磁盘，往往什么都看不到

第一反应是扫大文件。结果：安装目录近 15 分钟没有任何 >3 MB 的新文件，`ComponentStore` 为空，`Download` 目录只有一个 25 KB 的 JSON。

**因为它是流式下载，数据先进内存，不落盘。**

### 2. 用"网卡速率 vs 进程磁盘写入"判断是不是流式

```powershell
# 网卡 10 秒接收了多少
$n1=(Get-NetAdapterStatistics | Measure-Object -Property ReceivedBytes -Sum).Sum
Start-Sleep 10
$n2=(Get-NetAdapterStatistics | Measure-Object -Property ReceivedBytes -Sum).Sum
"网卡接收 $([math]::Round(($n2-$n1)/1KB,0)) KB"

# 每个进程这 10 秒读写了多少
$s1=@{}; foreach($p in Get-CimInstance Win32_Process){ $s1[$p.ProcessId]=@($p.ReadTransferCount,$p.WriteTransferCount) }
Start-Sleep 10
foreach($p in Get-CimInstance Win32_Process){
  if($s1.ContainsKey($p.ProcessId)){
    $w=$p.WriteTransferCount-$s1[$p.ProcessId][1]
    if($w -gt 51200){ '{0} pid={1} 写={2} KB/s' -f $p.Name,$p.ProcessId,[math]::Round($w/1KB/10,0) }
  }
}
```

判读方式：

- 网卡在跑、进程写盘 ≈ 0 → **流式**（数据被读进内存后直接消费掉，可能是云端处理、也可能只是还没落盘）
- 网卡在跑、某个进程写盘也很大 → **正在落盘**，那就是下载/解压，直接看这个进程是谁

这次就是靠第二种判读抓到 `update.exe (pid 36632) 76,417 KB/s 写盘`，一秒钟定位真凶。

### 3. 关于归因：我一度把那段流量算成了字幕识别

实验前半段（16:44–17:09）我看到 `Cache\audioWave\*.waveDataV2` 被写了 159 MB、`Cache\recognize\*.aac` 有 4 MB，判断"这波流量是字幕识别"。

这个判断对那段时间**基本成立**：该窗口网卡只有 0.5–2 MB/s，属于后台零散流量。真正 4–5 MB/s 的持续跑量出现在**重装并重启之后**，那才是安装包。

真正的教训是：**不要用"某个缓存文件被动过"去推断网卡跑量来自哪里**。可靠的判据是量级和持续性——零散的 1–2 MB/s 是素材与识别，持续吃满 4–5 MB/s 数分钟才是拉包。两者的区分必须靠持续采样，而不是单点快照。

### 4. 一个坑：非交互环境里 `FileSystemWatcher` 不触发

我一开始用 `Register-ObjectEvent` + `FileSystemWatcher` 做"写入即刻记录"，日志二十多分钟零事件。用测试文件验证：

```powershell
# 在被监视目录建个测试文件，看会不会记到日志里
Set-Content -LiteralPath "$env:LOCALAPPDATA\CapCut\__fsw_test.txt" -Value 'test'
```

结果 `Created=0`——因为脚本跑在非交互 runspace 里，没人泵事件队列。**这类监控在后台脚本里不可靠，改用定时轮询枚举更稳。**

---

## 四、关于"本地开关"，一个容易被误解的点

网上常见说法是"剪映的 `globalSetting` 改了也没用，服务端强制更新"。这次实测的结论更细：

| 观察 | 结论 |
|---|---|
| 开关设 `true`，然后正常启动、正常剪辑 | 16:44–17:09 **只有 0.5–2 MB/s** 的零散流量，没有大文件落盘，`update.exe` 没出现——**"允许"不等于"立刻下载"** |
| 开关设 `true`，**重装 3.6 安装包并重新启动** | 8 分钟内以 4–5 MB/s 拉完约 1.8 GB 并安装——**触发点是"安装/启动后的检查"** |
| 开关设 `false` + 文件加只读，连续多轮启动、重启 | 网卡只有 **3 KB/s**，`update.exe` 零进程——**开关是有效的** |
| 安装完成后，程序自己把 `globalSetting` 改写成了 `true`（大小从 3,162 B 变 6,788 B） | 它会**自己改回**来，所以"只改值不加只读"等于没改 |

所以准确的表述是：

> 本地开关有效：`false` 时确实不会下载。但 `true` 只代表"允许"，真正按下开始键的是一次**安装或启动后的检查**；一旦下载启动，它会自己把配置改回 `true`，并在你退出/重启的间隙完成替换和删除旧版。

配置里真正相关的四个键（注意第四个是拼错的 `Swtich`）：

```ini
enableAutoUpdate=false
totalSilentUpgradeSwitch=false
debugSilentUpgradeSwitch=false
upgradeIntervalMin=99999999999
```

---

## 五、封锁：三层防线（全部不碰网络）

### 第一层：禁止 `update.exe` 执行，但**不删文件**

这是最关键的一步。很多人第一反应是删掉 `update.exe`，结果是**启动器找不到它，软件直接不显示界面**——这个坑我踩过。

正确做法是给它加一条 `Deny ExecuteFile` 的 ACL：文件还在，程序能检查到它的存在，但它执行不起来。

```powershell
$sid = New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')  # Everyone
$acl = Get-Acl -LiteralPath 'D:\CapCut\CapCut\3.6.0.1318\update.exe'
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $sid, [System.Security.AccessControl.FileSystemRights]::ExecuteFile, 'Deny')
[void]$acl.AddAccessRule($rule)
Set-Acl -LiteralPath 'D:\CapCut\CapCut\3.6.0.1318\update.exe' -AclObject $acl
```

实测：加完之后三个 `CapCut.exe` 进程照常启动、界面正常、剪辑与字幕识别都不受影响。而且这一步**不需要管理员权限**，不弹 UAC。

### 第二层：配置写 false + 设只读，断掉"自己改回去"

```powershell
(Get-Item -LiteralPath $cfg).IsReadOnly = $false
# 写入四个键...
(Get-Item -LiteralPath $cfg).IsReadOnly = $true
```

实测：加只读之后，程序启动、重启都没能改写它，mtime 一直停在写入时刻。

### 第三层：修正 `Configure.ini` / `ProductInfo.xml` 的版本指向

安装器有时会把 `last_version` 写成某个已经不存在的版本（我遇到的是写成了 `9.8.0.4213`，而该目录已被清掉）。这会让启动器认为"目标版本缺失"，从而触发新一轮下载。把它改回现存版本即可：

```ini
[capcut]
last_version=3.6.0.1318
```

`ProductInfo.xml` 里补上 `appver=3.6.0`、`full_appver=3.6.0.1318`，避免它把"信息缺失"当成"需要重装"。

### 可选第四层：锁安装目录的写入权

想让"下载完了也装不进去"，可以拒绝 `D:\CapCut\CapCut` 的 `CreateFiles / AppendData / Delete` 权限。代价是程序自己写 `Configure.ini` 那一下会失败（一般不影响使用）。这一步我留作备用，没有默认上。

---

## 六、两个千万别做的事

### 1. 别按域名封更新

这些域名**是复用的**：

| 域名 | 承担的业务 | 封掉的后果 |
|---|---|---|
| `sf16-web-tos-buz.capcutstatic.com` | 静态 CDN，**更新包在这里**，同时也在供素材/字体/模板缩略图 | 更新停了，素材和模板大面积缺资源 |
| `*.capcutapi.com`（`editor-api` / `commerce-api` / `feed-api` / `tnc-sg` …） | 业务接口：登录、云端识别、草稿同步、额度校验 | **字幕识别直接不可用** |
| `lf16-effectcdn.byteeffecttos-g.com` | 特效资源 CDN | 特效、转场、贴纸加载失败 |

再加上两个现实障碍：Windows 防火墙**不支持域名规则**，只能按程序或 IP；而这些 CDN 全部指向 Akamai 边缘节点（`23.200.156.x` 之类），**同节点混跑不同业务**，IP 封不准还会轮换。应用自带 `sscronet` / `TTNetDownloaderCrossPlatform.dll`，hosts 也不一定拦得住。

### 2. 别只"改一下 ini 里的 false"就以为完事

它会在安装完成后自己把配置改回 `true`。**值 + 只读位，两个都得做。**

---

## 七、万一已经被换了版本，怎么回滚

我的处理顺序（已验证可行）：

1. **先别启动新版。** 一旦启动，它就会把旧版目录删掉，回收站都不留。
2. **备份现场**：把根目录 `CapCut.exe`、`uninst.exe`、`Configure.ini`、`ProductInfo.xml` 复制到别处。
3. **保留旧版安装包**（我这份是 526 MB 的 `CapCut_3_6_0_1318_..._creatortool.exe`，网盘备份地址见下面的小节）。重装它就能把**版本目录 + 旧启动器**一起恢复——这很重要，因为旧启动器通常没有备份，回收站里也找不到。
4. **重装后先封锁，再启动。** 这一步我是踩过坑才总结出来的：当时是"重装完直接启动"，结果 8 分钟内它就把 1.8 GB 拉完装上了。正确顺序是 重装 → 跑 `capcut_ban_update.bat` → 启动验证。
5. 验证：启动后 60 秒采样，空闲状态下只应有几百 KB；`update.exe` 零进程；版本目录只有一个。

草稿格式不用担心：我核对了 `draft_content.json` 的 `version` 字段，即使被新版打开保存过，仍是 `360000`，旧版可以继续打开。

### 3.6.0.1318 安装包下载

回滚的前提是手里有那个完整的旧版安装包。官方早就下架了 3.6，能重装 3.6 的只有这个 526 MB 的 `CapCut_3_6_0_1318_capcutpc_0_creatortool.exe`。我上传了一份到百度网盘：

- 链接：https://pan.baidu.com/s/15qe3TY-oo-Z6L3wVkh5naA?pwd=r6i6
- 提取码：`r6i6`

**文件校验值**（下完先比对，别直接双击）：

```
文件名: CapCut_3_6_0_1318_capcutpc_0_creatortool.exe
大小:   551,573,144 字节（约 526 MB）
版本:   3.6.0.1318
SHA-256: 232C6F7789A8D56A918EE2D348E53F28F9AE7734F26DDD6B551076396FD5FB3C
```

校验命令（PowerShell 里跑，输出的 Hash 与上面一致就行）：

```powershell
Get-FileHash -LiteralPath '.\CapCut_3_6_0_1318_capcutpc_0_creatortool.exe' -Algorithm SHA256
```

拿到后建议先核对三样东西再装：文件名里的版本是 `3_6_0_1318`、体积是 551,573,144 字节、SHA-256 对得上。装完立刻按第八节的脚本封锁，**别先启动**——先启动就前功尽弃，它会当场把 1.8 GB 的新版拉下来。

> 网盘链接是自愿分享的备份，与本项目无隶属关系；如果哪天失效，请在本仓库提 issue。

---

## 八、脚本：一条 bat 搞定

仓库里给了两个文件，放在同一目录：

- `capcut_ban_update.ps1` —— 主逻辑：定位安装目录、锁 `update.exe`、改四个开关并设只读、修 `Configure.ini`、按程序加防火墙规则（管理员时）
- `capcut_ban_update.bat` —— 双击入口，自动请求管理员权限，跑完 `pause` 让你看结果

脚本是**幂等**的，重复跑不会叠加规则（会先清掉旧的 Deny 再加一条）。

跑出来的报告长这样：

```
================ CapCut 禁止更新 ================
管理员权限：否（防火墙规则会跳过，ACL 与配置照常生效）
安装目录：D:\CapCut\CapCut
发现 update.exe：1 个
  [OK] 已禁止执行 update.exe，Deny=1  (D:\CapCut\CapCut\3.6.0.1318\update.exe)
  [OK] 已关闭更新开关并设为只读：...\Config\globalSetting
        enableAutoUpdate = false
        totalSilentUpgradeSwitch = false
        debugSilentUpgradeSwitch = false
        upgradeIntervalMin = 99999999999
  [OK] Configure.ini last_version -> 3.6.0.1318
================ 校验 ================
  Deny=1  ...\update.exe
```

验证是否封成功，最简单的方法是：

```powershell
# 启动软件后采样 60 秒
$n1=(Get-NetAdapterStatistics | Measure-Object -Property ReceivedBytes -Sum).Sum
Start-Sleep 60
$n2=(Get-NetAdapterStatistics | Measure-Object -Property ReceivedBytes -Sum).Sum
"60 秒接收 $([math]::Round(($n2-$n1)/1KB,0)) KB"
```

正常编辑时的量级是 **几百 KB 到几 MB**（素材、缩略图、识别）；如果在**空闲状态**下持续跑 3–5 MB/s 好几分钟，那就是又在拉包了。

---

## 九、一句话总结

它不靠你点"同意"，靠的是**启动器在后台拉包、更新器在你退出时静默替换、重启后顺手删掉旧版**。

想按住它，别在网络上较劲（会连带封死字幕识别），去按住**那个更新执行器**：文件不删、权限禁执行、配置加只读、版本指向修正。四件事做完，软件照常能用，但版本再也换不掉。

> 注：文中出现的 `D:\CapCut` 只是路径示例，请按你自己机器的实际安装目录替换；脚本会自动从注册表和常见位置探测，不依赖这个示例。
