# 模拟 Air724UG 设备（MQTT），用于验证服务端链路
import json
import time
import paho.mqtt.client as mqtt

IMEI = "TESTIMEI001"
BROKER = "127.0.0.1"
PORT = 1883


def on_connect(client, userdata, flags, rc):
    print(f"[sim] connected rc={rc}", flush=True)
    # 订阅服务端指令主题
    client.subscribe(f"cmd/{IMEI}", qos=1)
    # 上报在线
    client.publish(f"device/{IMEI}/online",
                   json.dumps({"type": "online", "imei": IMEI, "phone": "13800138000"}),
                   qos=1, retain=True)


def on_message(client, userdata, msg):
    print(f"[sim] recv topic={msg.topic} payload={msg.payload.decode()}", flush=True)
    try:
        data = json.loads(msg.payload.decode())
    except Exception:
        return
    if data.get("type") == "task" and data.get("taskId"):
        task_id = data["taskId"]
        task = data.get("task")
        result = None
        error = None
        if task == "get_temperature":
            result = 28.5  # 模拟温度
        elif task == "get_config":
            result = "module(..., package.seeall)\nMQTT_HOST = '1.2.3.4'\n"
        else:
            result = "模拟结果"
        resp = {"type": "task_result", "taskId": task_id, "task": task, "result": result, "error": error}
        client.publish(f"device/{IMEI}/result", json.dumps(resp), qos=1)


client = mqtt.Client(client_id=IMEI, protocol=mqtt.MQTTv311)
client.on_connect = on_connect
client.on_message = on_message
client.connect(BROKER, PORT, 30)
print("[sim] loop start", flush=True)
client.loop_forever()
