
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-VL-2B-Instruct",
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "text", "text": "Describe what you see in each image."},
          {"type": "image_url", "image_url": {"url": "http://localhost:9000/img.jpg"}},
          {"type": "image_url", "image_url": {"url": "http://localhost:9001/img2.jpg"}}
        ]
      }
    ],
    "max_tokens": 256
  }'
