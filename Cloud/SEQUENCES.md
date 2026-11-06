# UPasswords v1 交互时序

本文按仓库当前实现整理客户端、API、MariaDB 与 R2 的交互。云端数据表及关系见
[数据库设计 ER 图](DATABASE.md#er-图)；端点以 `Cloud/api/internal/api/router.go` 为准。
生产条目、附件、冲突和改密接口要求 `X-UPW-Sync-Protocol: 5`。
除认证与库注册表路径（`/v1/vaults/{vaultId}`）外，下图中的 `/seq`、`/changes`、
`/items`、`/attachments`、`/conflicts` 和 `/rekey` 均相对
`/v1/vaults/{vaultId}`；省略查询参数时以图中说明为准。

## 账户登录与密码库绑定

macOS、iOS 与浏览器扩展都直接通过 HTTPS 调用 API。账户验证码认证和密码库解锁是两件事：
验证码签发账户会话，密码库主密码只在客户端用于解封 VEK。

~~~mermaid
sequenceDiagram
    autonumber
    actor User as 用户
    participant Client as macOS / iOS / 浏览器扩展
    participant API as Cloud API
    participant DB as MariaDB
    participant SMTP as 邮件服务

    User->>Client: 输入邮箱并请求验证码
    Client->>API: POST /v1/auth/code
    API->>DB: 保存验证码键控哈希、过期时间及审计记录
    API->>SMTP: 发送邮件验证码
    API-->>Client: 202 Accepted
    User->>Client: 输入验证码
    Client->>API: POST /v1/auth/verify
    API->>DB: 校验并消费验证码；查找或创建用户
    API->>DB: 保存会话令牌 SHA-256 摘要
    API-->>Client: 返回 bearer token、sessionId 和到期时间
    Client->>API: GET /v1/vaults
    API->>DB: 查询该用户的密码库注册表
    API-->>Client: 返回 vaultId、名称及密码版本
    alt 新建云密码库
        Client->>Client: 本地生成 VEK，并用主密码封装信封
        Client->>API: POST /v1/vaults，提交名称和加密信封
        API->>DB: 创建 vaults 注册记录
        API-->>Client: 返回 vaultId
    else 绑定已有密码库
        Client->>API: GET /v1/vaults/{vaultId}
        API->>DB: 读取信封和密码版本
        API-->>Client: 返回加密信封
        Client->>Client: 用主密码解封并核对 VEK，再记录本地绑定
    end
~~~

## macOS 与 iOS 行级同步

两种原生客户端共用 `UPasswordsPersistence.RowSync`。本地 `.upw` 是离线数据源，
`.upwsync` 保存游标、revision、基线和待处理状态。同步先拉取远端变更，再上传本地脏行；
服务端只接收行密文和附件密文。

~~~mermaid
sequenceDiagram
    autonumber
    actor User as 用户
    participant App as macOS AppContext / iOS Vault
    participant Local as 本地加密库与同步状态
    participant Sync as RowSync
    participant API as Cloud API
    participant DB as MariaDB
    participant R2 as Cloudflare R2

    User->>App: 新增、修改或删除条目
    App->>Local: 先保存加密 .upw 与本地变更
    App->>Sync: 自动或手动启动同步
    Sync->>API: GET /v1/vaults/{id} 读取库元数据与信封版本
    API->>DB: 读取信封、passwordVersion、headSeq
    API-->>Sync: 返回库元数据
    Sync->>Sync: 检查会话代次、VEK、脏行及 revision
    alt 游标有效
        loop 按页读取增量
            Sync->>API: GET /changes?since=cursor
            API->>DB: 读取 item_changes 与对应当前行
            API-->>Sync: 返回密文行、删除或裁决事件及新游标
            Sync->>Sync: 本地解密并校验；按可信基线合并非重叠修改
        end
    else 游标过期且本地无待处理数据
        API-->>Sync: 410 cursor_expired
        Sync->>API: GET /seq 获取快照起始 headSeq
        API->>DB: 读取 headSeq 与 passwordVersion
        API-->>Sync: 返回快照边界
        Sync->>API: GET /items 分页读取快照
        API->>DB: 读取 vault_sync_items
        API-->>Sync: 返回全量密文行
        Sync->>API: GET /changes?since=snapshotHead 追赶快照期间的变更
        API->>DB: 读取边界后的变更与当前行
        API-->>Sync: 返回增量和新的 headSeq
        Sync->>Sync: 验证快照并应用增量
    else 本地有待处理内容或冲突标记
        Sync->>Sync: 停止自动重建并要求先完成保护性恢复
    end
    opt 有待上传的附件版本
        Sync->>API: PUT /attachments/{id}?version=...&upload=...
        API->>R2: 写入临时密文对象
        Sync->>API: POST /attachments/{id}/commit
        API->>R2: 读取暂存对象、校验摘要并发布不可变对象
        API->>DB: 事务登记 attachment_versions 暂存版本元数据
        API-->>Sync: 返回版本提交结果
    end
    opt 有本地脏行
        Sync->>API: POST /items，携带 baseRevision、密文与附件引用
        API->>DB: CAS 校验并事务写行、item_changes、墓碑和 headSeq
        API-->>Sync: 返回逐行成功、冲突或删除结果
        alt CAS 成功
            Sync->>Sync: 更新 revision 和加密共同基线
        else revision 已变化
            Sync->>Sync: 尝试安全三方合并并重试；无法合并则登记冲突候选
        end
    end
    Sync->>Local: 校验会话仍有效后提交库快照和同步状态
    Local-->>App: 发布同步完成状态
~~~

CAS 冲突不按设备时钟覆盖。可靠共同基线上的互不重叠更改可由客户端合并；其余情况保留候选，
等待用户裁决。条目行、变更事件、删除墓碑及游标状态分别由服务端事务和本地原子快照维护。

## 浏览器扩展同步与编辑

Chrome、Edge、Firefox 与 Safari 扩展共用 `WebExtensions/shared` 的 Relay API、同步逻辑和
IndexedDB 加密快照。同步刷新读取并验证云端数据；条目编辑则单独提交 CAS 写入。

~~~mermaid
sequenceDiagram
    autonumber
    actor User as 用户
    participant UI as 扩展弹窗
    participant Session as 扩展解锁会话
    participant IDB as IndexedDB 加密快照
    participant API as Cloud API
    participant DB as MariaDB

    User->>UI: 登录后解锁或刷新密码库
    UI->>IDB: 读取账户隔离的密文快照与游标
    UI->>API: GET /v1/vaults/{id}/seq
    API->>DB: 读取 headSeq、passwordVersion
    API-->>UI: 返回版本信息
    alt 首次同步、缓存缺失或需要重建
        UI->>API: GET /v1/vaults/{id} 获取加密信封
        API->>DB: 读取密码库信封
        API-->>UI: 返回信封和快照边界
        UI->>API: GET /items 分页读取密文行
        API->>DB: 查询 vault_sync_items
        API-->>UI: 返回快照页
    else 已有可用快照
        UI->>UI: 以 IndexedDB 快照作为拉取基线
    end
    loop 按页读取基线之后的变更
        UI->>API: GET /changes?since=cursor
        API->>DB: 查询事件与当前行
        API-->>UI: 返回增量变更页
        UI->>UI: 应用密文行、删除或原子裁决事件
    end
    UI->>API: GET /v1/vaults/{id}/seq 确认期间版本未变化
    API->>DB: 读取 headSeq、passwordVersion
    API-->>UI: 返回最终版本
    UI->>Session: 请求验证新行及隔离异常行
    Session->>Session: 用 VEK 解密并验证条目密文
    UI->>IDB: 原子提交行、游标、版本与隔离记录
    UI->>Session: 发布已验证快照供界面读取
    Session-->>UI: 返回解密后的界面模型

    User->>UI: 编辑并保存条目
    UI->>Session: 请求用 VEK 加密更新内容
    Session-->>UI: 返回条目密文
    UI->>API: POST /items，携带 baseRevision 与密文
    API->>DB: CAS 更新条目并追加 item_changes、推进 headSeq
    alt CAS 成功
        API-->>UI: 返回新 revision
    else 条目 revision 已变化或已删除
        API-->>UI: 返回冲突或删除错误，保留本地编辑供处理
    end
~~~

扩展同步在检测到 `headSeq` 或 `passwordVersion` 于同步期间改变时重试，不将半套快照写入 IndexedDB。
条目编辑 API 与刷新流程分开；写入成功后，其他设备及扩展缓存通过后续增量同步收到该变更。

## Safari 自动填充原生桥

Safari Web Extension 的自动填充桥用于读取 macOS App Group 中的本地加密快照，
不代理云同步请求。主应用负责推送加密 `.upw` 与 `.upwkey`；扩展进程解锁后只在内存缓存候选。

~~~mermaid
sequenceDiagram
    autonumber
    actor User as 用户
    participant Page as 网页与 Content Script
    participant Extension as Safari Web Extension
    participant Handler as SafariWebExtensionHandler
    participant Group as App Group 加密快照
    participant App as macOS UPasswords

    App->>Group: 原子写入 .upw、.upwkey 与 current 标记
    Page->>Extension: 请求当前网页的匹配凭据
    Extension->>Handler: sendNativeMessage(query / ping)
    Handler->>Group: 读取活动库加密快照
    alt 原生桥尚未解锁
        Handler-->>Extension: 返回 locked 状态
        User->>Extension: 输入主密码
        Extension->>Handler: sendNativeMessage(unlock)
        Handler->>Group: 读取 .upw 与 .upwkey
        Handler->>Handler: 本地解封 VEK、解密库并缓存候选
        Handler-->>Extension: 返回解锁结果
    end
    Extension->>Handler: sendNativeMessage(query, 当前站点)
    Handler-->>Extension: 返回匹配凭据候选，供用户选择
    User->>Extension: 选择要填充的凭据
    Extension->>Page: 将用户选择的字段填入网页
~~~

## 附件密文上传与下载

附件内容在客户端以独立 DEK 加密，DEK 由 VEK 包装。R2 保存附件密文；MariaDB 保存版本、摘要、
大小、包装后的 DEK 和当前引用。对象存储和 MariaDB 不共享事务，因此上传先暂存对象再提交版本。

~~~mermaid
sequenceDiagram
    autonumber
    participant Client as macOS / iOS / 浏览器扩展
    participant API as Cloud API
    participant R2 as Cloudflare R2
    participant DB as MariaDB

    Client->>Client: 用 DEK 加密附件；用 VEK 包装 DEK；计算密文摘要
    Client->>API: PUT /attachments/{id} 上传密文
    API->>R2: 写入 staging 临时对象
    API-->>Client: 上传接收确认
    Client->>API: POST /attachments/{id}/commit，提交版本元数据
    API->>R2: 读取暂存对象并校验摘要、大小
    API->>R2: 写入按附件 ID、版本和摘要寻址的不可变对象
    API->>DB: 事务登记 attachment_versions 不可变版本
    API-->>Client: 返回提交结果
    Client->>API: POST /items，附带条目密文和完整附件版本引用
    API->>DB: 同事务 CAS 更新条目、attachments 当前引用及 item_changes
    API-->>Client: 返回条目 revision

    Client->>API: GET /attachments/{id}?version=...
    API->>DB: 校验密码库归属并查询对象键与 DEK 包装
    API->>R2: 读取指定版本的附件密文
    R2-->>API: 返回密文对象
    API-->>Client: 返回密文、摘要和包装后的 DEK
    Client->>Client: 校验摘要、用 VEK 解包 DEK 并解密附件
~~~

## 冲突候选与用户裁决

冲突候选保留加密内容。服务端在登记时核对当前 revision 或持久删除序号；裁决时再次校验
候选完整集合、generation 和当前状态，避免过期客户端覆盖新数据。

~~~mermaid
sequenceDiagram
    autonumber
    participant A as 客户端 A
    participant B as 客户端 B
    participant API as Cloud API
    participant DB as MariaDB

    A->>API: POST /items，以旧 baseRevision 尝试 CAS
    API->>DB: 读取当前行并比较 revision
    DB-->>API: revision 已变化
    API-->>A: 返回当前 revision 与密文
    A->>A: 尝试共同基线三方合并
    alt 可安全合并
        A->>API: POST /items，以最新 revision 重试
        API->>DB: CAS 更新并写 item_changes、headSeq
        API-->>A: 返回成功
    else 需要人工裁决
        A->>API: POST /items/{uuid}/conflicts 登记本地候选
        API->>DB: 事务保存 item_conflicts、候选和附件版本引用
        API-->>A: 返回 conflictId 与 generation
        B->>API: GET /conflicts
        API->>DB: 查询未决冲突及密文候选
        API-->>B: 返回候选与当前状态
        B->>B: 用户比较候选并选择结果
        B->>API: POST /conflicts/{id}/resolve，提交完整候选 ID 集和 CAS 状态
        API->>DB: 锁定并核验 generation、候选集合和当前 revision/删除序号
        API->>DB: 同事务写入胜出行或墓碑、裁决事件并推进 headSeq
        API->>DB: 保留候选与附件引用 30 天
        API-->>B: 返回裁决结果
        A->>API: GET /changes?since=cursor
        API->>DB: 读取原子裁决事件及结果行
        API-->>A: 返回 resolve 事件
        A->>A: 更新本地条目、基线和游标
    end
~~~

## 主密码与 VEK 轮换

改密由已解锁客户端生成新 VEK 并在本地重加密。服务端先锁定该库的普通写入，
暂存条目、附件 DEK 包装及冲突候选；全部清单匹配后才原子切换信封和密码版本。

~~~mermaid
sequenceDiagram
    autonumber
    participant Client as 发起改密的 macOS / iOS 客户端
    participant API as Cloud API
    participant DB as MariaDB
    participant Peer as 其他设备

    Client->>Client: 验证旧主密码并生成新 VEK、信封
    Client->>API: POST /rekey/begin，提交新信封及条目、附件数量
    API->>DB: 保存新信封、创建 rekeys 任务并固定条目/附件/候选数量
    API-->>Client: 返回 rekeyId 与版本信息
    Client->>API: GET /rekey/{id}/conflicts 分页读取候选清单
    API->>DB: 读取本次改密固定的冲突候选
    API-->>Client: 返回候选密文及旧候选身份
    loop 分批暂存新密钥下的密文
        Client->>Client: 用新 VEK 重加密条目和冲突候选；重新包装附件 DEK
        Client->>API: POST /rekey/{id}/chunk 与 /conflicts
        API->>DB: 写入 rekey_staging、rekey_attachment_staging、rekey_conflict_staging
        API-->>Client: 返回已暂存数量
    end
    Client->>API: POST /rekey/{id}/commit
    API->>DB: 校验清单数量、身份覆盖和候选 ID 唯一性
    API->>DB: 单事务替换行密文、DEK 包装和候选；追加 rekey 事件
    API->>DB: 更新 envelope_enc、password_version、headSeq 并清除暂存
    API-->>Client: 返回新 passwordVersion
    Peer->>API: GET /seq 或 GET /changes
    API->>DB: 读取密码版本与 rekey 事件
    API-->>Peer: 返回版本变化
    Peer->>API: GET /v1/vaults/{id} 读取新信封
    API->>DB: 读取当前信封
    API-->>Peer: 返回加密信封
    Peer->>Peer: 要求用新主密码解锁，再重建本地同步状态
~~~

## 主要实现位置

- 原生同步编排：`Apple/macOS/Sources/UPasswords/App/AppContext+Sync.swift`、`Apple/iOS/Services/Vault+Sync.swift`
- 共用原生行同步：`SwiftPackages/Persistence/Sources/UPasswordsPersistence/RowSync.swift`
- 浏览器扩展同步：`WebExtensions/shared/src/sync/vault-sync.ts`
- 浏览器扩展 API：`WebExtensions/shared/src/api/relay.ts`
- Safari 原生桥：`Apple/SafariWebExtension/SafariWebExtensionHandler.swift`
- 服务端路由：`Cloud/api/internal/api/router.go`
