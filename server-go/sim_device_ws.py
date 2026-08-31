# 模拟 Air724UG 设备（MQTT over WebSocket），验证服务端 ws listener 链路
import json
import time
import paho.mqtt.client as mqtt

IMEI = "WSIMETEST01"
# 公网 wss：https://panel.example.com/websocket -> host + 443 + TLS
# 内网明文 ws：BROKER = "127.0.0.1", WS_PORT = 9527, 并去掉 tls_set()
BROKER = "panel.example.com"
WS_PORT = 443
USE_TLS = True  # True=wss(443), False=ws(9527)


def on_connect(client, userdata, flags, rc):
    print(f"[sim-ws] connected rc={rc}", flush=True)
    client.subscribe(f"cmd/{IMEI}", qos=1)
    client.publish(f"device/{IMEI}/online",
                   json.dumps({"type": "online", "imei": IMEI, "phone": "13900139000"}),
                   qos=1, retain=True)


def on_message(client, userdata, msg):
    print(f"[sim-ws] recv topic={msg.topic} payload={msg.payload.decode()}", flush=True)
    try:
        data = json.loads(msg.payload.decode())
    except Exception:
        return
    if data.get("type") == "task" and data.get("taskId"):
        task_id = data["taskId"]
        task = data.get("task")
        result = 26.5 if task == "get_temperature" else "ws模拟结果"
        resp = {"type": "task_result", "taskId": task_id, "task": task, "result": result, "error": None}
        client.publish(f"device/{IMEI}/result", json.dumps(resp), qos=1)


client = mqtt.Client(
    callback_api_version=mqtt.CallbackAPIVersion.VERSION1,
    client_id=IMEI,
    protocol=mqtt.MQTTv311,
    transport="websockets",
)
client.ws_set_options(path="/websocket")
if USE_TLS:
    client.tls_set()  # wss：校验服务器证书
client.on_connect = on_connect
client.on_message = on_message
client.connect(BROKER, WS_PORT, 30)
print("[sim-ws] loop start", flush=True)
client.loop_forever()
