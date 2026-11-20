# 普通版雨课堂协议核对

初次协议核对日期：2026-11-13；功能调整：2026-11-14。新项目独立编写；以下源码用于核对接口、字段与行为，未复制上游实现。

- course_helper：`70c8584433f762df0ebb3fa412187c7dba0549cd`。
- ykt_assistant：`4c91f96e115ad35e661ee2b55c225e5d68d1036e`。该仓库 README 明确尚无 LICENSE，不能据此认定已获复制或再分发许可。
- 普通版官方页面：<https://www.yuketang.cn/v2/web/index> 与 <https://www.yuketang.cn/m/v2/lesson/student/0/overview>，当日资源版本 `1.2.354`。

## 课程与历史课堂

官方 `pc.3518d2db.js` 定义 `/v2/api/web` 前缀。学生首页 `getList` 使用 `GET /v2/api/web/courses/list?identity=2`，成功外壳为 `errcode:0`，列表 `data.list`。官方仅将大列表前 20 项先行渲染，随后展示全部；此处不是服务端分页。

学生课程项关联 `classroom_id`、班级 `name`、`course.id/name`、`teacher.name`。归档弹窗使用 `GET /v2/api/web/classroom_archive?user_id=<uid>`，学生列表为 `data.classrooms`，每项 `id` 代表班级。新项目以班级 ID 去重，并检查同一班级是否返回不一致课程 ID。上游两项目均曾只按课程 ID 合并，可能混合同课程下不同班级；course_helper 还只遍历正在上课列表，导致非实时课程不显示。

官方 `32598.0121dbe0.js` 学生课堂记录 `getList`：

```text
GET /v2/api/web/logs/learn/<classroomId>
actype=14&page=0&offset=20&sort=-1
```

`data.activities` 为记录，`data.has_more` 决定后续页；页码从 0 起递增。课堂类型为 14，官方卡片也接受类型 3，`courseware_id` 为单次课堂 ID。点击分支将类型 3 的已结束课堂路由到 `student-container`，类型 14 路由到新版页面；此区别不等同于已证实的 `oldVersion` 字段推导。`create_time` 由官网作为 JavaScript Date 的毫秒值使用。空页却标记还有下一页、重复页、关联 ID 不符均显式报错，避免把动态列表误当完整历史。

## 登录与课堂凭证

course_helper `lib/api/login.dart`、`lib/api/course.dart` 与 ykt_assistant `docs/rain-classroom-api.md`、`RainApi.java` 对照：

| 功能 | 方法及端点 | 已核对字段 |
| --- | --- | --- |
| 二维码 | GET `/api/v3/user/login/pre-info` | `data.token/qrImage/qrContent` |
| 扫码等待 | POST `/api/v3/user/login` | `{token}`；等待超时业务码 50001 |
| 用户资料 | GET `/v/course_meta/user_info` | `data.user_profile.user_id/name/school` |
| 发送短信 | POST `/api/v3/user/code/send` | `phoneNumber,email,ticket,rand` |
| 短信校验 | POST `/api/v3/user/code/verify` | `phoneNumber,email,code` |
| 账号登录 | POST `/api/v3/user/login/app` | type 1 手机密码、2 邮箱密码、3 短信；`pushDeviceId,ticket,rand` |
| 实时课堂 | GET `/api/v3/classroom/on-lesson` | `data.onLessonClassrooms` |
| 入课签到 | POST `/api/v3/lesson/checkin` | `{source:21,lessonId,joinIfNotIn:true}` |
| 动态二维码解析 | POST `/api/v3/app/scan` | `{url}`；`data.value` 为课堂 ID |

账号凭证为响应 Cookie；HTTP 课堂凭证为签到响应头 `set-auth`；WebSocket 凭证为 `data.lessonToken`，两者不能互换。仅允许 HTTPS `www.yuketang.cn`，禁自动重定向；CSRF 从适用路径的 Cookie 获取。Cookie 回调串行保存，退出及新登录轮次使迟到响应无效。图片与七牛上传使用无账号拦截器的独立客户端。

官网 `pc.3518d2db.js` 新版实时列表使用 `/api/v3/classroom/on-lesson-upcoming-exam`，其 `getOnLesson` 的 `onLessonClassrooms` 条目由 `openFullscreen` 读取 `courseId/classroomId/lessonId`。为兼容已在上游使用的 `/on-lesson` 响应，新项目仅在关联 ID 缺失时用当前 `lesson_id` 的 `lesson-info` 补全，同时校验已有 ID。扫码进入同样通过 `lesson-info` 获取正式课程、班级 ID，不能从课堂 ID 猜测。

## 课堂报告、课件及本人答案

官方 mobile bundle 和 `24358.ace5e054.js`：使用账号 Cookie 读取学生 `lesson-info`、`detail`、`review`，均位于 `/api/v3/classroom-report/student/`，参数 `lesson_id`。签到状态使用 `detail.detail.valid/checkInTime`，不会从某个工具或课件状态猜签到结果。

上游脱敏响应 `android/app/src/test/resources/captured-history-redacted.json` 的 `lesson-info.data` 包含显式 `oldVersion:false`，历史列表尚无该字段样本。新项目先读取此元信息；若服务端明确返回 `oldVersion=true`，保留到 `Lesson` 并显示暂不支持详情，不继续请求新版报告、课件、本人答案。列表仅在自身带显式标记时可预标；不从活动类型 3 或 ID 大小推断，不宣称能识别所有早期课堂。旧版详情按用户 2026-11-14 的要求不适配。对应 true 分支测试使用同层级最小模拟响应，不冒充真实旧版账号实测。

历史原课件：`GET /api/v3/classroom-report/student/ppt?lesson_id=...&presentationId=...`，`48679.56d15b64.js` 明确取 `data.slideList`，学生只显示 `visible` 页面。实时课件使用课堂 Bearer：`GET /api/v3/lesson/presentation/fetch?presentation_id=...`，取 `data.slides`。

官方 `90500.cfbd8a04.js` 将 `detail.problem.studentList` 绑定本人的题目列表。`89458.8fbee808.js` 的学生题目组件读取 `problemId`、`problem_type`、`isAnswered`、`result`、`problemscore`；只有明确 `isAnswered=true` 才记录本人已作答。状态字段缺失显示未知。

历史课堂使用官网 `pc.3518d2db.js` 定义、`95924.10988234.js` 调用的 `GET /api/v3/lesson-summary/student/presentation?lesson_id=...&presentation_id=...`，响应 `data.presentation/data.slides`。官方 `formatPresentation` 将 `slide.result` 绑定到 `slide.problem.result`；`addProblem` 以 `slide.problem.problemId` 关联题目，`slide.result.answer` 为本人答案。其完成条件是 `!!result && result.score !== null`，因此分数 0 和 -1 均已完成，-1 代表待批改；无 result 或 score:null 为暂无提交。结果对象缺少 score 字段或已完成却缺少 answer 必须标为未知，不以 `problem.content.answer` 补齐。正分数按官网 `/100`，0 和负状态值原样保留。summary 接口请求不可用时回退课堂报告，成功响应结构损坏时直接报告未知。这是课后数据协议，不能用其空结果证明进行中的课堂尚未提交。

2026-11-20 重新读取公开普通版直播入口，仍为 `lesson/3.3.241`。`fullscreen.b2d05c0f1c969680f5d5.js` 的 `/v3/:lessonID` 路由加载 `12.7a3c38d7e231e5b9793c.js`；其 `getPresentation` 用课堂 Bearer 调用 `GET /api/v3/lesson/presentation/fetch?presentation_id=<id>`。直播 `addProblem` 直接以 `slide.problem.result` 的真值决定已完成，主观题组件 `16.89f06c9fa277deceeb6f.js` 将 `this.oProblem.result` 原样用于本人结果展示；这里的 `result` 本身是选项/填空数组或主观对象，不是课后摘要的 `{score,answer}` 包装，也不依赖已批分。`null` 表示未提交，JavaScript 的空数组、空对象仍是真值，不能仅因容器为空就重判未作答。未提供 `result` 字段、结构错误或归属不符仍报告未知；不会从题目标准答案字段补齐。

1.1.1 的实时答案读取使用当前课堂会话的上述直播端点；只有历史读取沿用 summary/报告。最终按用户要求，进入及新课件加载时复用课件响应的本人结果，成功提交后读取该课件一次，另保留用户主动刷新；周期轮询、课堂事件与自动提交前不再额外查询答案。类型 1/2/3/4/6 要求数组，类型 5 要求对象，来源标记为服务端；直播 `problem.score` 是题目满分，不冒充个人得分。以上核对使用公开官方脚本，未访问用户账号或真实课堂响应；真实课堂返回仍以用户测试为准。

官方 `25711.629d13aa.js` 的个人题目详情请求：

```text
GET /api/v3/classroom-report/problem/student-answer
identityId=<lessonInfo.identityId>&problemId=<id>&lesson_id=<lessonId>
```

**`data.problem.result` 为本人答案；`data.content.answer` 为标准答案，不可混用。** 选择、投票、填空为 result 数组，主观题为对象；完整详情分数 `problem.score` 按 100 换算。未能读取个人答案仍保留课件，并以 `answersKnown=false/answerError` 报告未知，不能显示为未作答或用标准答案冒充。

答题提交：`POST /api/v3/lesson/problem/answer`，课堂 Bearer，JSON `{problemId,problemType,dt,result}`，`dt` 为当前 Unix 毫秒。type 1/2/3/4/6 使用数组，type 5 使用 `{content,pics,videos}`。课堂端还应在提交前检查题目开放状态和已答状态，接口本身不推测是否开放。

## 位置签到

`GET /api/v3/lesson/location-checkin/eligibility` 携带课堂 Bearer，返回 `signed`、`needLocationSignIn` 和 `session.centerLat/centerLng`（或完整 `lat/lng`）、地址。手动提交前逐次展示并确认；1.1 增加自动位置签到，1.1.1 按用户要求合并到自动签到开关，开启时统一确认后后续各轮自动提交。旧配置仅普通自动签到时先关闭，重新开启时取得位置签到同意。使用服务端中心坐标，不是手机 GPS 测量值。明确 `signed=true` 可作为已签到证据，即使普通课堂报告尚未同步；新一轮签到会使旧轮证据失效。

`POST /api/v3/lesson/location-checkin/submit`：`{lat,lng,lessonId,source:54,address}`。提交前再次查询并比对签到轮次与完整坐标，提交后查询 `signed=true` 才确认成功。`locationcheckinext/locationcheckinend/lessonfinished` 应调用 `locationRoundChanged` 使旧确认失效。已接受但尚待确认的相同轮次不重复 POST。

## 上传与已移除功能

官方 `24358.ace5e054.js` 请求 `GET /api/v3/classroom-report/replay?lesson_id=...&canFakeLive=1`；`data.live[]` 中 `url` 为片段地址，可能是 HLS，`duration` 为毫秒。若 `record` 恰为单项，官方将 `record[0].mp4` 作为首段地址。`data.textWatermark` 的姓名、学号、院系、班级在播放时保留显示。上述为初版核对记录；2026-11-14 按用户要求已移除回放请求、播放器及其依赖。

图片上传先以账号 Cookie `POST /pc/generate_qiniu_token`，JSON `{bucket_name:"cms-attachment",expired_time:3600}`；再独立客户端 `POST https://upload.qiniup.com/`，multipart `file/token/key/fname`。成功资源地址为 `https://qn-scd1.yuketang.cn/<key>`，返回 `pic/thumb` 供主观题提交。

## 实时课堂补充

当日普通版官方课堂入口 `https://www.yuketang.cn/lesson/fullscreen/v3/0` 使用 `lesson/3.3.241/js/fullscreen.b2d05c0f1c969680f5d5.js`。已核对每 30 秒应用心跳 `{op:"xintiao",lessonid}`，不能以 WebSocket ping 代替；`problemfinished.prob` 表示教师收题；`presentationupdated/created.presentation` 要重新读取课件并获取时间线。

懒加载题目组件 `16.89f06c9fa277deceeb6f.js`：`extendtime.problem.prob` 精确关联题目，`limit` 是更新后的总时限，不能每次把 `extend` 加到旧值；`dt/now` 用于服务器时钟校准，`-1` 表示不限时。`probleminfo` 查询携带 `lessonid/problemid/msgid`，返回 `problemid/now/dt/limit`。从时间线恢复的题目先查询当前时限，避免把教师已经收回的题目重新开放；收题和下课在收到时立即阻止自动提交。

课堂记录的 `create_time` 在官网被直接传给 `new Date(value)`，数字按毫秒，日期字符串按其时区解析；没有证据支持把短数字自动乘 1000。真实账号返回形态仍需联调。

## 验证边界

本地协议测试使用自行编写的最小响应和模拟传输，不包含个人 Cookie、API key、姓名、课堂 ID 或课件签名。覆盖班级隔离、归档完整性、历史分页、本人答案与标准答案隔离、未知状态、Cookie 域限制和注销竞态、签到令牌、位置轮次与答题载荷。

以上官方前端证据证明客户端调用方式，不能证明当前账号权限或服务端所有返回变体。上游 ykt_assistant 历史夹具的题目和回放列表为空；真实 Android 扫码/密码/短信登录、正在上课、各题型答题、课堂报告、图片上传与服务端位置签到仍需用户登录实际课堂联调。接口变化必须基于实测响应更新，不猜测缺失字段。
