所有文件读写使用 UTF-8，修改时保留原有编码。PowerShell 读取中文前执行 chcp 65001 并设置 UTF-8 输出，使用 Get-Content -Encoding UTF8。代码注释使用中文。不要使用 sed/awk 处理中文文件。
