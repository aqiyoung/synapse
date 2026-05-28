"""知识库后端入口"""
import os
import sys

# 确保 data 目录存在
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(BASE_DIR, "data")
UPLOAD_DIR = os.path.join(BASE_DIR, "uploads")
os.makedirs(DATA_DIR, exist_ok=True)
os.makedirs(UPLOAD_DIR, exist_ok=True)

# 初始化数据库
from crud import init_db
init_db()

from api import app  # noqa: E402
