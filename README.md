# status-tool

`status-tool` 是一个使用 Zig 编写的轻量级状态探测工具，目标是替代 `fancyss` 里越来越重的 `ss_status.sh` / `ss_status_main.sh` 组合。

当前定位：

- 原生 TCP/HTTP/1.1 探测，不依赖 `curl`
- 支持 `once` 和 `daemon` 两种模式
- 支持 `direct` 和 `socks5` 两种出站方式
- 支持 IPv4 / IPv6 / auto 地址族
- 输出延迟、HTTP 状态码、对端地址、失败原因
- daemon 模式可持续写缓存文件，供前端或故障转移逻辑读取

## 命令

### 1. 单次探测

```bash
status-tool once \
  --url http://ip.sb \
  --family ipv4 \
  --proxy socks5://127.0.0.1:23456 \
  --warmup 1 \
  --attempts 2 \
  --timeout-ms 3000 \
  --format json
```

### 2. 使用配置文件做单次批量探测

```bash
status-tool once --config ./status.json
```

### 3. 守护模式

```bash
status-tool daemon --config ./status.json
```

## 配置文件

```json
{
  "interval_ms": 5000,
  "state_file": "/tmp/status-tool.json",
  "output": "json",
  "probes": [
    {
      "name": "china",
      "url": "http://ip.ddnsto.com",
      "family": "ipv4",
      "mode": "direct",
      "warmup": 0,
      "attempts": 1,
      "timeout_ms": 3000
    },
    {
      "name": "foreign",
      "url": "http://ip.sb",
      "family": "ipv4",
      "mode": "socks5",
      "proxy": "socks5://127.0.0.1:23456",
      "warmup": 1,
      "attempts": 2,
      "timeout_ms": 3000
    }
  ]
}
```

## 输出

`json` 模式会输出统一结构：

```json
{
  "updated_at_ms": 1775740000000,
  "results": [
    {
      "name": "foreign",
      "url": "http://ip.sb",
      "ok": true,
      "status_code": 200,
      "elapsed_ms": 143,
      "remote_addr": "127.0.0.1:23456",
      "error": "ok",
      "attempts": 2,
      "warmup": 1
    }
  ]
}
```

## 与 fancyss 的关系

建议后续接入方式：

- 前端页面刷新时优先读取 daemon 缓存，不主动触发真实探测
- 故障转移逻辑读取 daemon 最近结果
- shell 仅保留为兼容层，用来组装参数并调用 `status-tool`

这样能同时消掉两类成本：

- shell / awk / sed / grep / curl 的多进程开销
- 页面刷新导致的真实状态探测重入

