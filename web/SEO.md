# 官网搜索与 AI 检索维护

本轮参考：[Julian Goldie 的 AI SEO 视频](https://www.youtube.com/watch?v=ifEPcAJbtZw)（2026-10-06）。采用的流程是查找搜索需求缺口、改进低点击页面、核对真实产品体验、提供明确下一步，再用等长区间数据复核。视频展示的流量与转化数字不是 MacClean 的预测或成果。

2026-10-07 发布记录：新增中文/英文指南目录，以及系统数据、微信媒体和 Xcode 缓存指南，目标网址由 10 个扩展为 18 个。已在原官网静态目录发布并核对 259 个公开文件的 SHA-256；旧站备份为 `/var/backups/macclean-web/seo-20261007-20261007T082052.452228Z.tar.gz`。本次仅更新静态文件，没有修改 Caddy 配置或重启后台。

本地结构检查与公网 18 页、46 个静态目标完整检查通过；公网浏览器完成 390、1024、1440 像素宽度共 36 组页面检查，FAQ、目录锚点、手机菜单、双向语言切换和下载入口正常。中英文指南实际点击到各自下载页，安装包按钮可用；未触发安装包下载，以免污染下载计数。原有 301、404、noindex、XML/纯文本类型及 API 健康也已验证。

公网验证器处理 Cloudflare 自动注入的邮箱保护链接：只跳过带有效十六进制邮箱令牌的 `/cdn-cgi/l/email-protection` 伪链接，其余 CDN 资源仍检查。部分 CDN 脚本 GET 为 200 而 HEAD 为 404，静态资源检查在 HEAD 404/405 时再尝试 GET；两种方法均失败才报告缺失。实际联系入口已用浏览器确认解码为 mailto。

本轮部署、文件清单、截图与浏览器结果保存在 `../reports/evidence/seo-2026-10-07/`。本轮 Search Console 浏览器连接超时，未取得当前查询、展示与点击数据，也未新增提交或请求收录。下文 2026-10-03 数字仍是历史基线，不表示本轮优化效果。

规范域名为 `https://thulem.com`。目标收录页面：首页、下载、支持、隐私与用户协议，以及清理指南目录和 3 篇操作指南；各有中文和 /en/ 英文版本，共 18 个网址。购买、订单和错误页面保留 noindex；后台/API 不参与搜索。

## 修改与验证

中文 HTML 是标题、摘要及 FAQ 的来源，英文文案在 `site/assets/js/i18n.js`。修改正文后运行：

```sh
node web/site/dev/sync-partials.mjs # 仅修改公共 partial 后需要
node web/site/dev/build-seo.mjs
node web/site/dev/build-seo.mjs --check
python3 web/site/dev/check-seo.py # 本地结构、链接与中英文校验
python3 web/site/dev/check-seo.py --live # 公网技术检查，不代表已被 Google 收录
node web/site/dev/check-i18n.mjs
cd web/server && npm test && npm run check
```

生成器维护 canonical、Open Graph、JSON-LD、robots.txt 和 sitemap.xml。FAQ 从可见正文提取。不添加虚构评分、销量、评论或价格；实际价格仍由服务端配置管理。站点地图不填虚假的每日更新时间。

操作指南的中英文文案及源码核对记录在 `site/dev/seo-guides.json`，模板在 `site/dev/build-guides.mjs`。源码路径只用于编辑核对，不会输出到公开页面。指南按系统数据、微信媒体与 Xcode 缓存三个不同问题组织，包含真实界面示例、文件用途、操作步骤、清理与恢复限制、相关指南与下载入口。选题来自已核实的产品功能，尚未用本轮 Search Console 查询数据验证需求量。

标题和摘要要说明本页能解决的问题，正文要兑现标题，不使用夸大的容量、速度或排名承诺。主页、支持页、导航和页脚提供可抓取的指南链接；中英指南正文均为静态 HTML，语言切换保留对应主题。保留现有功能和下载流程。

### 用真实查询数据决定下一轮

从现有 `sc-domain:thulem.com` 的“效果”导出查询 CSV，可同时导出页面 CSV。使用 `site/dev/analyze-search-console.py --help` 查看参数。工具识别中英文列名，将品牌词、相关非品牌词与旧 PDF 等无关流量分开，筛出需要检查落地页的需求缺口候选，以及展示量达到阈值、排名靠前但点击率低的页面候选。

只有查询表不能证明没有对应页面，查询与页面独立导出也不能推断一一对应。先在 Search Console 对选定查询查看“网页”，再判断应新增内容还是修改现有页。点击率需结合排名、国家、设备和展示样本判断；小样本不直接用于改版。该工具不登录 Google，也不把样例输入当作真实业绩。

本轮网页上线后，在 2026-10-14 检查新页面抓取/规范网址，2026-10-21 和 2026-11-04 对比等长区间的相关查询展示、点击和 CTR；比较时排除原站旧 PDF 工具流量。没有新增定时任务。这些是复核节点，不是流量提升承诺。

Google 的生成式 AI 展示报告已在部分资源推出，若当前资源显示该报告，可核对 AI 展示、页面、国家和设备；不能假设每个资源已可用，也不能把其中的展示数当作付费转化。[官方公告](https://developers.google.com/search/blog/2026/06/gen-ai-performance-reports)

Google 仍要求可抓取、对人有帮助的内容和清晰的网站结构；`llms.txt`、结构化数据和站外提及不保证 AI 推荐。[Google 官方 AI 搜索建议](https://developers.google.com/search/docs/fundamentals/ai-optimization-guide) 本轮不新增多站互链或站外自动发文。

`site/llms.txt` 是额外的产品事实与页面索引，功能变化时同步维护；它不是搜索或 AI 平台承诺采用的收录协议。中英文现在使用独立静态网址，正文无需 JavaScript 即可读取；各自 canonical，互相声明 hreflang。根目录中文和 /en/ 英文页面固定语言，不按浏览器设置自动替换。生成器需要 Node.js 与 Python 3 标准库，没有新增运行时服务或 npm 依赖。

## 部署与提交

1. 将 `web/site/` 公开内容部署到现有 `/var/www/thulem.com`，排除 `dev/`。无需新增运行服务。
2. 将 `web/server/deploy/Caddyfile.snippet` 的首页 301 和 X-Robots-Tag 配置合并进现有站点块；执行 `caddy validate`，成功后 reload，不覆盖其他站点。
3. 公网检查首页、下载页、支持页、robots.txt、sitemap.xml、llms.txt 返回 200；不存在的 URL 返回 404；index.html 返回 301。确认内容类型正确，XML/文本请求不能回退到首页 HTML。
4. 在 Google Search Console、Bing Webmaster Tools、百度搜索资源平台验证所有权，提交 `https://thulem.com/sitemap.xml`，对首页与下载页请求抓取。验证 token 必须使用平台真实签发值。
5. 检查 Cloudflare robots 注入、WAF、Bot Fight Mode 与 AI 爬虫设置。源码的允许规则不能覆盖 CDN 拦截。Googlebot、Bingbot、OAI-SearchBot 等搜索爬虫不应遇到登录、403 或验证码。搜索与训练爬虫分开管理，无需为 ChatGPT 搜索开启训练抓取。
6. 用 Rich Results Test / Schema Markup Validator 检查上线 JSON-LD。FAQ 标记不保证获得 FAQ 富结果。
7. 观察抓取错误、索引页面、搜索词、展现与点击。围绕真实功能和清理限制推广，避免批量堆砌关键词页面。

订单/购买页没有在 robots 禁止抓取，以便爬虫读取 noindex。robots 不是权限控制，后台与订单继续依赖现有鉴权。

2026-10-03 已将本次 SEO 修改部署到现有官网。上线前备份：`/var/backups/macclean-web/seo-20261003-080615.tar.gz`。服务器执行 `caddy validate` 通过，重载后 Caddy 与 macclean-server 均为 active。已部署不等于已向站长平台提交或已被搜索引擎收录。

## 官方参考

- Google AI 搜索建议：https://developers.google.com/search/blog/2025/05/succeeding-in-ai-search
- OpenAI 爬虫说明：https://developers.openai.com/api/docs/bots

上线公网复核：5 个收录页面的 canonical / JSON-LD / 新资源版本均正确；sitemap.xml 返回 200 XML 且包含 5 个 URL；llms.txt 返回 200 纯文本；robots.txt 保留站点地图声明。以 Googlebot、bingbot、OAI-SearchBot User-Agent 请求首页均返回 200（仅验证请求可达，不代表真实爬虫已抓取）。购买、订单、后台返回 noindex 响应头；健康接口正常。curl 确认 index.html → / 为 301，不存在页面为 404。一次默认 Python User-Agent 请求 index.html 返回 403，curl 复核正常；站长平台仍应检查真实爬虫的 CDN 抓取情况。


## 2026-10-03 Search Console 真实基线

来源：已登录的 `sc-domain:thulem.com` 资源。效果报告选中“3 个月”，图表实际有数据显示区间为 2026-07-27 至 2026-09-29。

| 指标 | 当前值 | 如何解释 |
|---|---:|---|
| 网页文本搜索曝光 | 76 | 原站历史数据，不是本次优化的新增效果 |
| 点击 | 2 | 首页 1 次、旧 /privacy/ 1 次 |
| 点击率 | 2.6% | 样本很小，暂不能判断标题优化效果 |
| 平均排名 | 34.7 | 跨查询聚合值，不是固定关键词排名 |
| 索引报告 | 7 已收录、8 未收录 | 报告更新到 2026-09-21，明显滞后 |

未收录原因：6 个重定向网址、2 个“已抓取 - 尚未编入索引”。重定向网址本身不收录通常正常，不能把这 8 个全部当作 SEO 故障。

首页 URL 检查显示“网址已收录到 Google”，抓取成功、允许索引；上次抓取显示 2026-10-03 09:51:03，当时尚未检测到用户 canonical 或引荐 sitemap，早于本轮部署。历史查询含 thulem、rotate pdf in chrome 等，历史页面含 /rotate-pdf/、/merge-pdf/；这些不是 MacClean 业务流量。

本轮将已 404 且有对应内容的 /privacy/、/terms/、/contact/ 分别 301 到现有隐私、条款与支持页面。旧 PDF 工具没有等价新页面，不能为了保留“收录数”全部跳转首页。

## 判断优化是否有效

- 部署当天：记录本基线。站点地图成功读取、真实 URL 检查可抓取是技术准入条件，不是流量效果。
- 第 7 天：检查首页、下载页和英文首页最后抓取时间、Google 选择的规范网址及索引状态。以 18 个目标网址为清单，不追求所有无用旧网址被收录。
- 第 14 / 28 天：效果报告按 MacClean 的 18 个网址过滤，对比前后等长区间；查看 MacClean 品牌词以及 Mac 清理、微信清理、磁盘空间分析等相关非品牌词。区分国家与设备，并排除旧 PDF 页面/查询造成的干扰。
- 看见曝光增长而点击不增长：检查具体查询、排名和对应标题摘要；点击增长但下载不增长：检查落地页与下载流程。
- 最终效果看搜索带来的真实下载、试用与付费。现有后台总下载/总订单不能直接当作 Google 转化，尚未接入搜索来源归因；GA4 或第一方事件统计应区分下载按钮点击、下载请求及实际完成，并防止把测试数据计为真实转化。
- AI 引用/流量另行观察：平台有 AI 搜索报告时查看该报告，同时用来源统计识别可见的 AI 引荐；llms.txt 可访问不等于模型已引用。

不能承诺“24 小时必收录”或“必上首页”。Google 官方说明抓取可能需要数天至数周，反复请求同一 URL 不会加快抓取。


第二轮部署：2026-10-03，备份 `/var/backups/macclean-web/seo-20261003-081818.tar.gz`；中英文 10 页公网 SEO 校验通过，中英语言切换浏览器验证通过，静态资源版本 `20261003.2`。Google 站点地图已正式提交；首次状态为“无法读取”，即使提交弹窗成功也不能记作读取成功。公网与服务器网络均需复核，最终处理状态以 Search Console 为准。

Search Console 后续核实：中英文首页均已成功“请求编入索引”，Google 明确提示加入优先抓取队列；这是排队，不是新页面已经收录。2026-10-03 16:46:28 的 sitemap.xml 实际网址测试显示“允许抓取：是、网页抓取：成功”，说明 Google 检查工具能读取该文件。但站点地图处理报告此前仍报“无法抓取”，该报告的处理成功状态尚未确认，不能以实时测试替代地图处理结果。

## 2026-10-03 功能与搜索意图文案调整

本轮关键词来自软件实际能力、用户问题与公开搜索结果的用语观察，没有 Keyword Planner 搜索量或竞争度数据；以下是目标词组，不是已验证的高流量关键词。

| 用户问题 / 目标词组 | 页面内容承担的回答 | 能力边界 |
|---|---|---|
| Mac 清理软件、Mac 磁盘空间不足、释放储存空间 | 首页主标题、简介与空间不足 FAQ：先分析、再选文件 | 不承诺固定释放 GB 或让 Mac 加速 |
| Mac 微信清理、微信占用太大、QQ / 企业微信缓存 | 聊天清理功能说明、媒体清理 FAQ | 不读取聊天数据库，不承诺自动识别联系人或保留已删媒体可用 |
| Mac 磁盘空间分析、大文件查找、系统数据占用大 | 存储地图说明、系统数据 FAQ | 系统数据不等于垃圾，分析只读 |
| Xcode DerivedData 清理、npm / pip / Gradle 缓存 | 开发工具说明、新增 Xcode FAQ | 可能重建或重下载；Archives 不当作普通缓存 |
| Ollama / Hugging Face / LM Studio 模型清理 | 模型 FAQ 与开发工具正文 | 模型默认不选中，再用可能需要重下载 |
| Mac 应用卸载、应用残留清理 | 应用管家说明、新增残留 FAQ | 用户检查关联数据，不承诺彻底抹除所有痕迹 |
| Mac 重复文件查找、相似照片整理 | 重复文件功能与 FAQ | 相似不等于相同，先预览，保留需要的副本 |
| 清理后空间没增加、Mac 缓存能不能删 | 新增操作影响 FAQ | 废纸篓、快照与统计更新会影响可用空间 |

中文与英文标题、摘要、可见正文和 FAQ 同步更新；结构化 FAQ 从正文生成。没有堆砌 meta keywords、伪造效果数字或创建重复关键词页面。关键词效果评估应对上述问题词组分别观察展现与点击，结合实际落地页；不能将旧 PDF 查询混入 MacClean 业务成效。

功能关键词文案已于 2026-10-03 部署，静态资源版本 `20261003.3`，备份 `/var/backups/macclean-web/keywords-20261003-090241.tar.gz`。中英文预览、280 个 HTML 翻译键、10 页静态 SEO 校验通过；本轮未更改服务配置。
