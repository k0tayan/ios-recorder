debug先の実機はssh ipadで接続できる。
com.sega.pjsekaiのアプリ名は「プロセカ」
プロセカ起動コマンド　ssh ipad "/var/jb/usr/bin/uiopen --bundleid com.sega.pjsekai" 2>&1 
fridaがインストールされてるので動的解析可能。

● Bash(ssh ipad "find /var/mobile/Containers/Data/Application -maxdepth 3 -name '.com.sega.pjsekai*' -o -name 'ios_recorder*' 2>/dev/null" 2>&1)                                                                                                                                                                                                         
  ⎿  /var/mobile/Containers/Data/Application/D5A71536-CF52-4E83-8887-3CCC811C67F2/tmp/ios_recorder.s
                                                                                                                                                                                                                                                                                                                                                         
● ソケット発見！SSHトンネル経由で接続して確認します。   