stop-regservice:
	touch stopregservice

stop-commentbot:
	touch stopcommentbot

stop-webui:
	touch stopwebui

stop-all: stop-regservice stop-commentbot stop-webui

start-regservice:
	nohup ./regservice.sh &

start-commentbot:
	nohup ./commentbot.sh &

start-webui:
	nohup ./webui.sh &

start-all: start-regservice start-commentbot start-webui

restart-regservice:
	./restart.sh regservice

restart-commentbot:
	./restart.sh commentbot

restart-webui:
	./restart.sh webui

restart-all: restart-regservice restart-commentbot restart-webui
