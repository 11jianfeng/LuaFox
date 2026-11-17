require "import"
import "android.app.*"
import "android.os.*"
import "android.widget.*"
import "android.view.*"
import "android.text.TextUtils"
import "android.content.Intent"
import "android.net.Uri"
import "android.graphics.Typeface"
import "android.graphics.drawable.GradientDrawable"
import "java.io.File"
import "java.io.FileInputStream"
import "java.io.FileOutputStream"
import "java.lang.reflect.Array"
import "java.lang.Thread"
import "androidx.appcompat.app.ActionBarDrawerToggle"
import "com.google.android.material.appbar.MaterialToolbar"
import "androidx.drawerlayout.widget.DrawerLayout"
import "com.google.android.material.navigation.NavigationView"
import "com.google.android.material.snackbar.Snackbar"
import "com.google.android.material.floatingactionbutton.FloatingActionButton"

-- 权限
pcall(function()
  activity.requestPermissions({
    "android.permission.READ_EXTERNAL_STORAGE",
    "android.permission.WRITE_EXTERNAL_STORAGE"
  }, 1)
end)

pcall(function() activity.setTheme(R.style.Theme_Material3_Blue_NoActionBar) end)

local density = activity.getResources().getDisplayMetrics().density
local function dp(n) return math.floor(n * density + 0.5) end
local MATCH = ViewGroup.LayoutParams.MATCH_PARENT
local WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

-- ===== 状态 =====
local currentPath = "/sdcard"
local clipPath, clipMode = nil, nil
local currentPage = 0

-- 前向声明
local refreshList, updateBottomBar, updateToolbarPath, updateFAB
local openFile, showMenu, makeListItem, doPaste, doRename
local confirmDelete, showConfirm, showCreateFolder, showProperties
local deleteRecursive, copyFile, copyRecursive

-- ===== 工具函数 =====
local function drawable(name)
  local id = activity.getResources().getIdentifier(name, "drawable", activity.getPackageName())
  return id ~= 0 and id or nil
end

local function toast(msg)
  pcall(function()
    Snackbar.make(activity.getWindow().getDecorView(), msg, Snackbar.LENGTH_SHORT).show()
  end)
end

local function getArrayLen(arr)
  if arr == nil then return 0 end
  return Array.getLength(arr)
end

local function formatSize(bytes)
  if bytes < 1024 then return bytes .. " B" end
  if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
  if bytes < 1024 * 1024 * 1024 then return string.format("%.1f MB", bytes / 1024 / 1024) end
  return string.format("%.2f GB", bytes / 1024 / 1024 / 1024)
end

local function formatDate(ms)
  return os.date("%Y-%m-%d %H:%M", math.floor(ms / 1000))
end

-- 获取 Unix 权限 / 所有者 / 用户组（借用 ls -ld 命令）
local function getFileAttributes(path)
  local perm, owner, group = "-", "-", "-"
  pcall(function()
    local cmd = string.format("ls -ld \"%s\"", path)
    local process = Runtime.getRuntime().exec(cmd)
    local reader = java.io.BufferedReader(java.io.InputStreamReader(process.getInputStream()))
    local line = reader.readLine()
    reader.close()
    if line then
      local parts = {}
      for w in string.gmatch(line, "%S+") do table.insert(parts, w) end
      if #parts >= 4 then
        perm = parts[1]
        owner = parts[3]
        group = parts[4]
      end
    end
  end)
  return perm, owner, group
end

-- ===== 文件操作 =====
deleteRecursive = function(f)
  if f.isDirectory() then
    local children = f.listFiles()
    if children then
      local len = getArrayLen(children)
      for i = 0, len - 1 do
        deleteRecursive(children[i])
      end
    end
  end
  return f.delete()
end

copyFile = function(src, dst)
  local fin = FileInputStream(src)
  local fout = FileOutputStream(dst)
  local inCh = fin.getChannel()
  local outCh = fout.getChannel()
  inCh.transferTo(0, inCh.size(), outCh)
  fin.close()
  fout.close()
end

copyRecursive = function(srcPath, dstPath)
  local src = File(srcPath)
  if src.isDirectory() then
    local dst = File(dstPath)
    if not dst.exists() then dst.mkdirs() end
    local children = src.listFiles()
    if children then
      local len = getArrayLen(children)
      for i = 0, len - 1 do
        local child = children[i]
        copyRecursive(child.getAbsolutePath(), dstPath .. "/" .. tostring(child.getName()))
      end
    end
  else
    copyFile(srcPath, dstPath)
  end
end

-- 计算文件夹内部的文件数和文件夹数
local function getDirectoryStats(file)
  local totalSize, fileCount, dirCount = 0, 0, 0
  local function scan(f)
    if f.isDirectory() then
      dirCount = dirCount + 1
      local children = f.listFiles()
      if children then
        local len = getArrayLen(children)
        for i = 0, len - 1 do scan(children[i]) end
      end
    else
      fileCount = fileCount + 1
      totalSize = totalSize + f.length()
    end
  end
  local children = file.listFiles()
  if children then
    local len = getArrayLen(children)
    for i = 0, len - 1 do scan(children[i]) end
  end
  return totalSize, fileCount, dirCount
end

-- ===== 根 DrawerLayout =====
local drawer = DrawerLayout(activity)
activity.setContentView(drawer)

local content = LinearLayout(activity)
content.setOrientation(1)
content.setBackgroundColor(0xFFF5F5F5)
drawer.addView(content, DrawerLayout.LayoutParams(MATCH, MATCH))

local toolbar = MaterialToolbar(activity)
toolbar.setTitle("Fox File Manager")
toolbar.setBackgroundColor(0xFF009688)
toolbar.setTitleTextColor(0xFFFFFFFF)
toolbar.setSubtitleTextColor(0xFFCCFFFFFF)
content.addView(toolbar, LinearLayout.LayoutParams(MATCH, dp(56)))

pcall(function()
  activity.setSupportActionBar(toolbar)
  local bar = activity.getSupportActionBar()
  if bar then bar.setDisplayHomeAsUpEnabled(true) end
end)

local mainFrame = FrameLayout(activity)
content.addView(mainFrame, LinearLayout.LayoutParams(MATCH, 0, 1.0))

local flipper = ViewFlipper(activity)
mainFrame.addView(flipper, FrameLayout.LayoutParams(MATCH, MATCH))

-- ===== 页面 1：文件浏览 =====
local p1 = LinearLayout(activity)
p1.setOrientation(1)
p1.setBackgroundColor(0xFFF5F5F5)

local actionBar = LinearLayout(activity)
actionBar.setOrientation(0)
actionBar.setBackgroundColor(0xFF00796B)
actionBar.setGravity(Gravity.CENTER_VERTICAL)
actionBar.setPadding(dp(4), dp(6), dp(4), dp(6))
p1.addView(actionBar, LinearLayout.LayoutParams(MATCH, WRAP))

local btnBack = TextView(activity)
btnBack.setText("←")
btnBack.setTextSize(22)
btnBack.setTextColor(0xFFFFFFFF)
btnBack.setPadding(dp(12), dp(4), dp(12), dp(4))
actionBar.addView(btnBack)

local tvPath = TextView(activity)
tvPath.setTextColor(0xFFFFFFFF)
tvPath.setTextSize(13)
tvPath.setSingleLine(true)
tvPath.setEllipsize(TextUtils.TruncateAt.START)
actionBar.addView(tvPath, LinearLayout.LayoutParams(0, WRAP, 1.0))

local btnRefresh = TextView(activity)
btnRefresh.setText("⟳")
btnRefresh.setTextSize(20)
btnRefresh.setTextColor(0xFFFFFFFF)
btnRefresh.setPadding(dp(10), dp(4), dp(10), dp(4))
actionBar.addView(btnRefresh)

local scroll = ScrollView(activity)
p1.addView(scroll, LinearLayout.LayoutParams(MATCH, 0, 1.0))

local listLayout = LinearLayout(activity)
listLayout.setOrientation(1)
scroll.addView(listLayout, ScrollView.LayoutParams(MATCH, WRAP))

-- 剪贴板栏
local bottomBar = LinearLayout(activity)
bottomBar.setOrientation(0)
bottomBar.setBackgroundColor(0xFFFFFFFF)
bottomBar.setPadding(dp(12), dp(10), dp(12), dp(10))
bottomBar.setGravity(Gravity.CENTER_VERTICAL)
bottomBar.setVisibility(View.GONE)
p1.addView(bottomBar, LinearLayout.LayoutParams(MATCH, WRAP))

local tvClip = TextView(activity)
tvClip.setTextSize(13)
tvClip.setTextColor(0xFF666666)
tvClip.setSingleLine(true)
bottomBar.addView(tvClip, LinearLayout.LayoutParams(0, WRAP, 1.0))

local btnPaste = Button(activity)
btnPaste.setText("粘贴")
btnPaste.setTextColor(0xFFFFFFFF)
btnPaste.setBackgroundColor(0xFF009688)
btnPaste.setPadding(dp(16), dp(6), dp(16), dp(6))
bottomBar.addView(btnPaste)

local btnCancelClip = Button(activity)
btnCancelClip.setText("取消")
btnCancelClip.setPadding(dp(12), dp(6), dp(12), dp(6))
bottomBar.addView(btnCancelClip)

flipper.addView(p1)

-- ===== 页面 2：常用目录 =====
local p2Scroll = ScrollView(activity)
local p2 = LinearLayout(activity)
p2.setOrientation(1)
p2.setBackgroundColor(0xFFF5F5F5)
p2.setPadding(dp(12), dp(12), dp(12), dp(12))
p2Scroll.addView(p2, ScrollView.LayoutParams(MATCH, WRAP))
flipper.addView(p2Scroll)

local shortcuts = {
  {"内部存储", "/sdcard", "📱"},
  {"下载", "/sdcard/Download", "⬇"},
  {"图片", "/sdcard/Pictures", "🖼"},
  {"相机", "/sdcard/DCIM", "📷"},
  {"音乐", "/sdcard/Music", "🎵"},
  {"视频", "/sdcard/Movies", "🎬"},
  {"文档", "/sdcard/Documents", "📄"},
  {"Android 数据", "/sdcard/Android", "⚙"},
}

local function updateNavChecked(idx)
  navView.setCheckedItem(idx)
  currentPage = idx
end

for _, item in ipairs(shortcuts) do
  local row = LinearLayout(activity)
  row.setOrientation(0)
  row.setGravity(Gravity.CENTER_VERTICAL)
  row.setPadding(dp(16), dp(14), dp(16), dp(14))
  row.setBackgroundColor(0xFFFFFFFF)
  row.setMinimumHeight(dp(56))

  local icon = TextView(activity)
  icon.setText(item[3])
  icon.setTextSize(22)
  icon.setPadding(0, 0, dp(12), 0)
  row.addView(icon)

  local info = LinearLayout(activity)
  info.setOrientation(1)
  row.addView(info, LinearLayout.LayoutParams(0, WRAP, 1.0))

  local name = TextView(activity)
  name.setText(item[1])
  name.setTextSize(15)
  name.setTextColor(0xFF333333)
  info.addView(name)

  local pathTv = TextView(activity)
  pathTv.setText(item[2])
  pathTv.setTextSize(11)
  pathTv.setTextColor(0xFF999999)
  info.addView(pathTv)

  local pathVal = item[2]
  row.onClick = function()
    currentPath = pathVal
    flipper.setDisplayedChild(0)
    updateNavChecked(0)
    refreshList()
    updateFAB()
    updateToolbarPath()
    scroll.scrollTo(0, 0)
  end

  local lpRow = LinearLayout.LayoutParams(MATCH, WRAP)
  lpRow.setMargins(0, 0, 0, dp(1))
  p2.addView(row, lpRow)
end

-- ===== 页面 3：关于 =====
local p3 = LinearLayout(activity)
p3.setOrientation(1)
p3.setBackgroundColor(0xFFF5F5F5)
p3.setGravity(Gravity.CENTER)
p3.setPadding(dp(24), dp(24), dp(24), dp(24))

local tvAboutIcon = TextView(activity)
tvAboutIcon.setText("🦊")
tvAboutIcon.setTextSize(64)
tvAboutIcon.setGravity(Gravity.CENTER)
p3.addView(tvAboutIcon)

local tvAboutName = TextView(activity)
tvAboutName.setText("Fox File Manager")
tvAboutName.setTextSize(22)
tvAboutName.setTextColor(0xFF333333)
tvAboutName.setGravity(Gravity.CENTER)
tvAboutName.setPadding(0, dp(12), 0, dp(4))
p3.addView(tvAboutName)

local tvAboutVer = TextView(activity)
tvAboutVer.setText("v1.0 · LuaAppX Pro")
tvAboutVer.setTextSize(14)
tvAboutVer.setTextColor(0xFF999999)
tvAboutVer.setGravity(Gravity.CENTER)
p3.addView(tvAboutVer)

flipper.addView(p3)

-- ===== FAB =====
local fab = FloatingActionButton(activity)
fab.setImageResource(android.R.drawable.ic_menu_add)
local lpFab = FrameLayout.LayoutParams(dp(56), dp(56))
lpFab.gravity = Gravity.BOTTOM + Gravity.END
lpFab.setMargins(0, 0, dp(16), dp(16))
mainFrame.addView(fab, lpFab)

-- ===== NavigationView =====
local navView = NavigationView(activity)
local lpNav = DrawerLayout.LayoutParams(dp(300), MATCH)
lpNav.gravity = Gravity.START
drawer.addView(navView, lpNav)

local header = LinearLayout(activity)
header.setOrientation(1)
header.setGravity(Gravity.BOTTOM)
header.setPadding(dp(16), dp(16), dp(16), dp(16))
header.setBackgroundDrawable(GradientDrawable(
  GradientDrawable.Orientation.TR_BL, { 0xFF4DB6AC, 0xFF009688, 0xFF00695C }))
local ivHeader = TextView(activity)
ivHeader.setText("🦊")
ivHeader.setTextSize(32)
header.addView(ivHeader)
local tvHeader = TextView(activity)
tvHeader.setText("Fox File Manager")
tvHeader.setTextColor(0xFFFFFFFF)
tvHeader.setTextSize(18)
tvHeader.setPadding(0, dp(8), 0, 0)
header.addView(tvHeader)
navView.addHeaderView(header)

local menu = {
  { title = "文件浏览", icon = drawable("ic_folder") or android.R.drawable.ic_menu_recent_history },
  { title = "常用目录", icon = drawable("ic_places") or android.R.drawable.ic_menu_myplaces },
  { title = "关于",     icon = drawable("ic_about") or android.R.drawable.ic_menu_info_details },
}
for i, v in ipairs(menu) do
  local mi = navView.getMenu().add(0, i - 1, i - 1, v.title).setCheckable(true)
  if v.icon then mi.setIcon(v.icon) end
end
navView.setCheckedItem(0)

-- ===== UI 更新函数 =====
updateToolbarPath = function()
  if currentPage == 0 then
    toolbar.setTitle("Fox File Manager")
    toolbar.setSubtitle(currentPath)
    tvPath.setText(currentPath)
  elseif currentPage == 1 then
    toolbar.setTitle("常用目录")
    toolbar.setSubtitle("")
  else
    toolbar.setTitle("关于")
    toolbar.setSubtitle("")
  end
end

updateBottomBar = function()
  if clipPath then
    bottomBar.setVisibility(View.VISIBLE)
    local modeText = clipMode == "copy" and "复制" or "剪切"
    tvClip.setText(modeText .. ": " .. tostring(File(clipPath).getName()))
  else
    bottomBar.setVisibility(View.GONE)
  end
end

updateFAB = function()
  if currentPage == 0 then fab.setVisibility(View.VISIBLE) else fab.setVisibility(View.GONE) end
end

-- ===== 打开文件 =====
openFile = function(path)
  local f = File(path)
  if not f.exists() or f.isDirectory() then return end
  local ext = tostring(f.getName()):match("%.(%w+)$")
  ext = ext and ext:lower() or ""
  local mimeMap = {
    txt = "text/plain", log = "text/plain", json = "application/json", xml = "text/xml",
    html = "text/html", htm = "text/html", css = "text/css", js = "application/javascript",
    jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png", gif = "image/gif",
    bmp = "image/bmp", webp = "image/webp", svg = "image/svg+xml",
    mp3 = "audio/mpeg", wav = "audio/wav", ogg = "audio/ogg", flac = "audio/flac",
    mp4 = "video/mp4", mkv = "video/x-matroska", avi = "video/x-msvideo",
    pdf = "application/pdf", apk = "application/vnd.android.package-archive",
    zip = "application/zip", rar = "application/x-rar-compressed",
  }
  local mime = mimeMap[ext] or "application/octet-stream"
  local ok = pcall(function()
    local intent = Intent(Intent.ACTION_VIEW)
    intent.setDataAndType(Uri.fromFile(f), mime)
    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    activity.startActivity(intent)
  end)
  if not ok then toast("系统限制无法直接打开该文件类型") end
end

-- ===== 属性对话框 =====
showProperties = function(path)
  local f = File(path)
  if not f.exists() then return end

  local dialog = Dialog(activity)
  dialog.requestWindowFeature(1)
  local layout = LinearLayout(activity)
  layout.setOrientation(1)
  layout.setPadding(dp(20), dp(16), dp(20), dp(8))
  layout.setBackgroundColor(0xFFFFFFFF)

  local tvTitle = TextView(activity)
  tvTitle.setText("属性")
  tvTitle.setTextSize(18)
  tvTitle.setTextColor(0xFF333333)
  layout.addView(tvTitle)

  local grid = LinearLayout(activity)
  grid.setOrientation(1)
  grid.setPadding(0, dp(12), 0, dp(12))
  layout.addView(grid)

  local function addRow(key, value)
    local row = LinearLayout(activity)
    row.setOrientation(0)
    row.setPadding(0, dp(6), 0, dp(6))
    local tvKey = TextView(activity)
    tvKey.setText(key)
    tvKey.setTextSize(14)
    tvKey.setTextColor(0xFF666666)
    row.addView(tvKey, LinearLayout.LayoutParams(dp(80), WRAP))
    local tvVal = TextView(activity)
    tvVal.setText(value)
    tvVal.setTextSize(14)
    tvVal.setTextColor(0xFF333333)
    row.addView(tvVal, LinearLayout.LayoutParams(0, WRAP, 1.0))
    grid.addView(row)
    return tvVal
  end

  addRow("名称", tostring(f.getName()))
  addRow("目录", f.getParent() or "/")
  addRow("类型", f.isDirectory() and "文件夹" or "文件")

  local sizeVal = addRow("大小", "计算中...")
  addRow("修改时间", os.date("%Y-%m-%d %H:%M:%S", math.floor(f.lastModified() / 1000)))

  local perm, owner, group = getFileAttributes(path)
  addRow("权限", perm)
  addRow("所有者", owner)
  addRow("用户组", group)

  local fileCountVal = addRow("文件数", "-")
  local dirCountVal = addRow("文件夹数", "-")

  if not f.isDirectory() then
    sizeVal.setText(formatSize(f.length()) .. " (" .. f.length() .. ")")
  else
    -- 异步计算文件夹大小，防止 UI 卡顿
    local runnable = luajava.createProxy("java.lang.Runnable", {
      run = function()
        local total, files, dirs = getDirectoryStats(f)
        local uiRunnable = luajava.createProxy("java.lang.Runnable", {
          run = function()
            sizeVal.setText(formatSize(total) .. " (" .. total .. ")")
            fileCountVal.setText(tostring(files))
            dirCountVal.setText(tostring(dirs))
          end
        })
        activity.runOnUiThread(uiRunnable)
      end
    })
    Thread(runnable).start()
  end

  local btnRow = LinearLayout(activity)
  btnRow.setOrientation(0)
  btnRow.setGravity(Gravity.END)
  layout.addView(btnRow)

  local btnClose = Button(activity)
  btnClose.setText("关闭")
  btnClose.setTextColor(0xFF009688)
  btnClose.onClick = function() dialog.dismiss() end
  btnRow.addView(btnClose)

  dialog.setContentView(layout)
  dialog.show()
end

-- ===== 确认对话框 =====
showConfirm = function(title, message, onOk)
  local dialog = Dialog(activity)
  dialog.requestWindowFeature(1)
  local layout = LinearLayout(activity)
  layout.setOrientation(1)
  layout.setPadding(dp(24), dp(20), dp(24), dp(16))
  layout.setBackgroundColor(0xFFFFFFFF)

  local tvTitle = TextView(activity)
  tvTitle.setText(title)
  tvTitle.setTextSize(18)
  tvTitle.setTextColor(0xFF333333)
  layout.addView(tvTitle)

  if message then
    local tvMsg = TextView(activity)
    tvMsg.setText(message)
    tvMsg.setTextSize(14)
    tvMsg.setTextColor(0xFF666666)
    tvMsg.setPadding(0, dp(12), 0, 0)
    layout.addView(tvMsg)
  end

  local btnRow = LinearLayout(activity)
  btnRow.setOrientation(0)
  btnRow.setGravity(Gravity.END)
  btnRow.setPadding(0, dp(16), 0, 0)
  layout.addView(btnRow)

  local btnCancel = Button(activity)
  btnCancel.setText("取消")
  btnCancel.onClick = function() dialog.dismiss() end
  btnRow.addView(btnCancel)

  local btnOk = Button(activity)
  btnOk.setText("确定")
  btnOk.onClick = function()
    dialog.dismiss()
    onOk()
  end
  btnRow.addView(btnOk)

  dialog.setContentView(layout)
  dialog.show()
end

-- ===== 重命名 =====
doRename = function(path)
  local input = EditText(activity)
  local oldName = tostring(File(path).getName())
  input.setText(oldName)
  input.setSelection(input.getText().length())

  local dialog = Dialog(activity)
  dialog.requestWindowFeature(1)
  local layout = LinearLayout(activity)
  layout.setOrientation(1)
  layout.setPadding(dp(24), dp(20), dp(24), dp(16))
  layout.setBackgroundColor(0xFFFFFFFF)

  local tvTitle = TextView(activity)
  tvTitle.setText("重命名")
  tvTitle.setTextSize(18)
  layout.addView(tvTitle)
  layout.addView(input, LinearLayout.LayoutParams(MATCH, WRAP))

  local btnRow = LinearLayout(activity)
  btnRow.setOrientation(0)
  btnRow.setGravity(Gravity.END)
  btnRow.setPadding(0, dp(16), 0, 0)
  layout.addView(btnRow)

  local btnCancel = Button(activity)
  btnCancel.setText("取消")
  btnCancel.onClick = function() dialog.dismiss() end
  btnRow.addView(btnCancel)

  local btnOk = Button(activity)
  btnOk.setText("确定")
  btnOk.onClick = function()
    local newName = tostring(input.getText().toString())
    if newName == "" then return end
    local parent = File(path).getParent()
    local dst = parent .. "/" .. newName
    if File(path).renameTo(File(dst)) then
      toast("重命名成功")
      dialog.dismiss()
      refreshList()
    else
      toast("重命名失败")
    end
  end
  btnRow.addView(btnOk)

  dialog.setContentView(layout)
  dialog.show()
end

-- ===== 删除 =====
confirmDelete = function(path)
  showConfirm("删除确认", "确定删除 " .. tostring(File(path).getName()) .. " 吗？", function()
    if deleteRecursive(File(path)) then
      toast("已删除")
      refreshList()
    else
      toast("删除失败")
    end
  end)
end

-- ===== 新建文件夹 =====
showCreateFolder = function()
  local input = EditText(activity)
  input.setHint("文件夹名")

  local dialog = Dialog(activity)
  dialog.requestWindowFeature(1)
  local layout = LinearLayout(activity)
  layout.setOrientation(1)
  layout.setPadding(dp(24), dp(20), dp(24), dp(16))
  layout.setBackgroundColor(0xFFFFFFFF)

  local tvTitle = TextView(activity)
  tvTitle.setText("新建文件夹")
  tvTitle.setTextSize(18)
  layout.addView(tvTitle)
  layout.addView(input, LinearLayout.LayoutParams(MATCH, WRAP))

  local btnRow = LinearLayout(activity)
  btnRow.setOrientation(0)
  btnRow.setGravity(Gravity.END)
  btnRow.setPadding(0, dp(16), 0, 0)
  layout.addView(btnRow)

  local btnCancel = Button(activity)
  btnCancel.setText("取消")
  btnCancel.onClick = function() dialog.dismiss() end
  btnRow.addView(btnCancel)

  local btnOk = Button(activity)
  btnOk.setText("创建")
  btnOk.onClick = function()
    local name = tostring(input.getText().toString())
    if name == "" then return end
    if File(currentPath .. "/" .. name).mkdirs() then
      toast("创建成功")
      dialog.dismiss()
      refreshList()
    else
      toast("创建失败")
    end
  end
  btnRow.addView(btnOk)

  dialog.setContentView(layout)
  dialog.show()
end

-- ===== 长按菜单 =====
showMenu = function(path, isDir)
  local options = {}
  if not isDir then
    table.insert(options, {"打开", function() openFile(path) end})
  end
  table.insert(options, {"复制", function()
    clipPath = path; clipMode = "copy"; updateBottomBar(); toast("已复制到剪贴板")
  end})
  table.insert(options, {"剪切", function()
    clipPath = path; clipMode = "cut"; updateBottomBar(); toast("已剪切到剪贴板")
  end})
  table.insert(options, {"重命名", function() doRename(path) end})
  table.insert(options, {"属性", function() showProperties(path) end})
  table.insert(options, {"删除", function() confirmDelete(path) end})

  local dialog = Dialog(activity)
  dialog.requestWindowFeature(1)
  local layout = LinearLayout(activity)
  layout.setOrientation(1)
  layout.setBackgroundColor(0xFFFFFFFF)
  for _, opt in ipairs(options) do
    local btn = TextView(activity)
    btn.setText(opt[1])
    btn.setTextSize(16)
    btn.setTextColor(0xFF333333)
    btn.setPadding(dp(24), dp(14), dp(24), dp(14))
    btn.onClick = function()
      dialog.dismiss()
      opt[2]()
    end
    layout.addView(btn)
  end
  dialog.setContentView(layout)
  dialog.show()
end

-- ===== 粘贴 =====
doPaste = function()
  if not clipPath then return end
  local src = File(clipPath)
  local baseName = tostring(src.getName())
  local dstPath = currentPath .. "/" .. baseName

  if clipMode == "cut" and src.getParent() == currentPath then
    toast("源和目标相同")
    return
  end

  local ext, base = "", baseName
  local dot = baseName:match("^.+(%..+)$")
  if dot then
    ext = dot
    base = baseName:sub(1, #baseName - #ext)
  end
  local counter = 1
  while File(dstPath).exists() do
    dstPath = currentPath .. "/" .. base .. " (" .. counter .. ")" .. ext
    counter = counter + 1
  end

  local ok, err = pcall(function()
    if clipMode == "cut" then
      if not src.renameTo(File(dstPath)) then
        copyRecursive(clipPath, dstPath)
        deleteRecursive(src)
      end
    else
      copyRecursive(clipPath, dstPath)
    end
  end)

  if ok then
    toast(clipMode == "cut" and "移动成功" or "复制成功")
    clipPath = nil
    clipMode = nil
    updateBottomBar()
    refreshList()
  else
    toast("操作失败: " .. tostring(err))
  end
end

-- ===== 列表项 =====
makeListItem = function(name, isDir, size, mtime, fullPath)
  local item = LinearLayout(activity)
  item.setOrientation(0)
  item.setGravity(Gravity.CENTER_VERTICAL)
  item.setPadding(dp(12), dp(8), dp(12), dp(8))
  item.setBackgroundColor(0xFFFFFFFF)
  item.setMinimumHeight(dp(64))

  -- 图标
  local iconView = ImageView(activity)
  local resName = isDir and "ic_folder" or "ic_file"
  local id = drawable(resName)
  if id then
    iconView.setImageResource(id)
    iconView.setColorFilter(isDir and 0xFFFFA000 or 0xFF607D8B)
    local lpIcon = LinearLayout.LayoutParams(dp(32), dp(32))
    lpIcon.setMargins(0, 0, dp(12), 0)
    item.addView(iconView, lpIcon)
  else
    local fallback = TextView(activity)
    fallback.setText(isDir and "📁" or "📄")
    fallback.setTextSize(24)
    fallback.setPadding(0, 0, dp(12), 0)
    item.addView(fallback)
  end

  -- 中间信息
  local info = LinearLayout(activity)
  info.setOrientation(1)
  item.addView(info, LinearLayout.LayoutParams(0, WRAP, 1.0))

  local tvName = TextView(activity)
  tvName.setText(name)
  tvName.setTextSize(15)
  tvName.setTextColor(0xFF333333)
  tvName.setSingleLine(true)
  tvName.setEllipsize(TextUtils.TruncateAt.MIDDLE)
  info.addView(tvName)

  if fullPath then
    local tvDetail = TextView(activity)
    tvDetail.setText(formatDate(mtime))
    tvDetail.setTextSize(12)
    tvDetail.setTextColor(0xFF999999)
    info.addView(tvDetail)

    -- 右侧大小
    local tvSize = TextView(activity)
    if isDir then
      tvSize.setText("--")
    else
      tvSize.setText(formatSize(size))
    end
    tvSize.setTextSize(12)
    tvSize.setTextColor(0xFF999999)
    tvSize.setPadding(dp(8), 0, 0, 0)
    item.addView(tvSize)

    item.onClick = function()
      if isDir then
        currentPath = fullPath
        refreshList()
        updateToolbarPath()
        scroll.scrollTo(0, 0)
      else
        openFile(fullPath)
      end
    end
    item.onLongClick = function()
      showMenu(fullPath, isDir)
      return true
    end
  end

  return item
end

-- ===== 刷新列表 =====
refreshList = function()
  listLayout.removeAllViews()
  tvPath.setText(currentPath)

  local dir = File(currentPath)
  if not dir.exists() or not dir.isDirectory() then
    local tv = TextView(activity)
    tv.setText("目录不存在或无权限: " .. currentPath)
    tv.setPadding(dp(16), dp(16), dp(16), dp(16))
    tv.setTextColor(0xFF999999)
    listLayout.addView(tv)
    return
  end

  if currentPath ~= "/" then
    local up = makeListItem("..", true, 0, 0, nil)
    up.onClick = function()
      local parent = File(currentPath).getParent()
      if parent then
        currentPath = parent
        refreshList()
        updateToolbarPath()
        scroll.scrollTo(0, 0)
      end
    end
    listLayout.addView(up)
  end

  local children = dir.listFiles()
  if children == nil then
    local tv = TextView(activity)
    tv.setText("无权限访问该目录，请在系统设置里授予存储权限")
    tv.setPadding(dp(16), dp(16), dp(16), dp(16))
    tv.setTextColor(0xFFFF6F00)
    listLayout.addView(tv)
    return
  end

  local files = {}
  local len = getArrayLen(children)
  for i = 0, len - 1 do
    files[#files + 1] = children[i]
  end

  table.sort(files, function(a, b)
    local aIsDir, bIsDir = a.isDirectory(), b.isDirectory()
    if aIsDir ~= bIsDir then return aIsDir end
    return tostring(a.getName()):lower() < tostring(b.getName()):lower()
  end)

  if #files == 0 then
    local tv = TextView(activity)
    tv.setText("（空目录）")
    tv.setTextColor(0xFF999999)
    tv.setPadding(dp(16), dp(24), dp(16), dp(24))
    listLayout.addView(tv)
  end

  for _, f in ipairs(files) do
    local item = makeListItem(
      tostring(f.getName()), f.isDirectory(),
      f.length(), f.lastModified(), f.getAbsolutePath()
    )
    local lp = LinearLayout.LayoutParams(MATCH, WRAP)
    lp.setMargins(0, 0, 0, dp(1))
    listLayout.addView(item, lp)
  end
end

-- ===== 事件绑定 =====
btnBack.onClick = function()
  local parent = File(currentPath).getParent()
  if parent then
    currentPath = parent
    refreshList()
    updateToolbarPath()
    scroll.scrollTo(0, 0)
  end
end

btnRefresh.onClick = function() refreshList() end
btnPaste.onClick = function() doPaste() end
btnCancelClip.onClick = function()
  clipPath = nil
  clipMode = nil
  updateBottomBar()
end

fab.onClick = function(view) showCreateFolder() end

-- ===== 侧边菜单 =====
navView.setNavigationItemSelectedListener({
  onNavigationItemSelected = function(item)
    local idx = item.getItemId()
    flipper.setDisplayedChild(idx)
    updateNavChecked(idx)
    drawer.closeDrawer(Gravity.START)
    updateFAB()
    updateToolbarPath()
    return true
  end,
})

local toggle = ActionBarDrawerToggle(activity, drawer, 0, 0)
drawer.addDrawerListener(toggle)
toggle.syncState()

function onOptionsItemSelected(item)
  if toggle.onOptionsItemSelected(item) then return true end
  return false
end

-- ===== 初始化 =====
updateFAB()
updateToolbarPath()
updateBottomBar()
refreshList()