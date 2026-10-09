# AnJing-E2EE-GO语言-端对端加密私密即时通讯

前期提要：这是一个双端加密的go即时通讯，本程序仅让用户与用户之间创建连接实现端对端通讯，所有聊天记录将不在服务器中存储，也无法通过技术手段查看到聊天记录。聊天记录一旦丢失将无法复原，历史消息备份也只是将加密后的数据传输到服务器，而不是直接明文存储，清空后将无法恢复。如果关闭历史记录则无任何技术手段可以恢复！


<img width="1050" height="667" alt="image" src="https://github.com/user-attachments/assets/4afbe578-3996-47de-8b0f-f25e77744cd6" />

自建多节点即时通讯平台的后台。包含协议定义、7 个 Go 微服务、端到端加密（E2EE）密钥交换、离线推送，以及一个可以打包成单个二进制、带网页安装向导的部署方式。客户端（Vue 参考实现、Flutter）可以自行定制
<img width="784" height="762" alt="image" src="https://github.com/user-attachments/assets/c28f0644-a0e6-46bb-8501-7525d3cb9ae3" />


本程序只提供VUE的SDK进行参考！可以自定义开发页面
多节点、音视频暂未在免费版上直接公布，当前单节点已经完全够用

当前测试：
小型测试：1核心2gb内存，可容纳数百人
起步测试：2核心4gb内存，3000+在线人数
中等测试：4核心8gb内存，10000+人数同时在线
大型测试：16核32g内存，50000+人数同时在线

<img width="1041" height="581" alt="image" src="https://github.com/user-attachments/assets/8a376171-648c-4eac-8db4-c5d0a078231c" />

整个后台已编译成一个静态二进制文件，服务器上不需要装 Go，也不需要源码。
anjing      程序（全部后台服务 + 安装向导，静态编译，无需安装 Go）
anjing.sh   控制脚本（安装、启动、停止、状态、日志、升级、卸载）

系统要求：Debian 或 Ubuntu，使用root 权限，能确保访问系统软件源和 github.com
<img width="785" height="749" alt="image" src="https://github.com/user-attachments/assets/d591d80d-3704-42f4-8f96-a4e7a000b1dd" />

安装
----
  sudo ./anjing.sh install

终端会打印一个带令牌的链接，用浏览器打开后按步骤完成：
环境检测 -> 安装依赖（MySQL、NATS）-> 配置 -> 启动服务 -> 完成。
云服务器需要在安全组放行 8081-8090 端口，或按终端提示用 SSH 隧道访问。

安装完成后控制脚本会复制到 /usr/local/bin/anjingctl，在任何目录都能用。

常用命令
--------
  sudo anjingctl status                   查看各服务状态
  sudo anjingctl start                    启动全部服务
  sudo anjingctl stop                     停止全部服务
  sudo anjingctl restart                  重启全部服务
  sudo anjingctl logs [服务] [-f]          查看日志
  sudo anjingctl install                  修改配置（重新运行向导）
  sudo anjingctl upgrade ./anjing           升级到新版本（保留旧版本可回滚）
  sudo anjingctl rollback                 回滚到升级前的版本
  sudo anjingctl uninstall                卸载程序和服务，保留配置和数据
  sudo anjingctl uninstall --purge        同时删除全部数据和数据库
  sudo anjingctl uninstall --purge --remove-deps
                                        再卸载由 AnJing 安装的 MySQL

安装位置
--------
  /opt/anjing/bin/anjing    程序
  /opt/anjing/.env        配置（数据库密码、密钥）
  /opt/anjing/certs/      JWT 签名密钥
  /opt/anjing/data/       上传的媒体文件


需要放行的端口（默认）：8081 网关、8082 账号、8085 媒体、8087 节点选择、8088 推送，
以及 8084 管理后台（如果没有选择只允许本机访问）。8083、8086、3306、4222 只监听本机，不要放行。
