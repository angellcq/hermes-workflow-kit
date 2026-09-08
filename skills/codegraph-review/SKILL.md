---
name: codegraph-review
description: "Use when 改代码前需评估波及面. 基于代码图谱的变更影响分析."
version: 1.0.0
platforms: [windows, linux, macos]
---

# Codegraph Review Skill

基于 `.codegraph/codegraph.db` 代码图谱做变更波及面评估，改代码前必查。

## 触发时机

修改任何高扇入文件、跨模块改动、删改公共方法签名前，先跑一遍本技能。

## 图谱数据模型

库：`.codegraph/codegraph.db`（SQLite）

- `nodes`：`id`(class:xxx/method:xxx)、`kind`(class/method/field/route)、`name`、`qualified_name`、`file_path`、`signature`
- `edges`：`kind` = contains / calls / imports / references / instantiates / implements / extends
- `files`：文件清单与哈希

## 常用查询

### 谁调用了某方法/类（按文件聚合）
```sql
SELECT DISTINCT ns.file_path FROM edges e
JOIN nodes nt ON nt.id=e.target JOIN nodes ns ON ns.id=e.source
WHERE nt.name='GzwLogUtil' AND e.kind IN ('calls','references');
```

### 某文件里的全部路由
```sql
SELECT name FROM nodes WHERE kind='route' AND file_path LIKE '%GzwTaskController%';
```

### 某类的公开方法签名
```sql
SELECT name, signature FROM nodes
WHERE kind='method' AND visibility='public' AND file_path LIKE '%gzw/impl/GzwDkServiceImpl%';
```

### 类继承/实现关系
```sql
SELECT ns.name, nt.name FROM edges e
JOIN nodes ns ON ns.id=e.source JOIN nodes nt ON nt.id=e.target
WHERE e.kind IN ('extends','implements');
```

## 变更波及面评估流程

1. **定位**：`sqlite3 .codegraph/codegraph.db "SELECT ..."` 找到待改符号的 node
2. **入度统计**：查 calls/references 边，统计调用方文件数
3. **分级判定**：
   - 入度 >100 → 高危，改动前需用户确认
   - 入度 20~100 → 中危，列全调用方清单
   - 入度 <20 → 低危，直接改
4. **输出评估报告**：改动符号 + 波及文件数 + 高危清单 + 建议

## 高扇入文件速查（本项目实测）

| 文件 | 入度 | 影响域 |
|---|---|---|
| clfbxdUtil/ByteGroup | 1156 | 加解密全链路 |
| sso/conf/BipSsoConfig | 386 | SSO 配置 |
| bill/rule/util/GuaranConTOOAVO | 275 | 担保合同 OA 推送 |
| tyjk/IQueryService | 196 | 全部 tyjk 规则主数据反查 |
| gzwutil/GzwLogUtil | 194 | 全部 gzw 推送日志 |
| utils/YmsHttpClientUtil | 131 | 75 个类全部外部 HTTP |
| dto/contract/Contract | 162 | contract 规则族 DTO |

## 注意

- `calls` 边只覆盖项目内方法；跨到平台 jar 的调用经字段注入统计
- 图谱库若过期，运行图谱生成工具刷新后再查
- 修改高扇入文件前，务必把评估报告附在任务卡里

## 在工作流中的位置与配合

本技能是**改码前的守门员**，被 `project-workflow` 在编码前、`kanban-executor` 在派发前调用。

- **上游**：`project-workflow` S4 拆出任务卡后，编码代理动刀**之前**先跑本技能
- **输出**：改动符号 + 入度清单 + 高危/中危/低危分级 → 附在任务卡里交给编码代理
- **下游**：`kanban-executor` 派发编码代理，改完后做完成验证闭环
- **配合要点**：入度 >100 的符号（ByteGroup 1156 / BipSsoConfig 386 等）改动前必须用户确认

**调用时机**：任何「改高扇入文件 / 跨模块改动 / 删改公共方法签名」之前。
