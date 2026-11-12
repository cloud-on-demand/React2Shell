FROM python:3.13-slim-bookworm

RUN python -m pip install --no-cache-dir ansible-core==2.21.6 ansible-navigator==26.10.0
RUN python -m pip install --no-cache-dir Pygments==2.20.0
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /lab
ENTRYPOINT ["ansible-navigator"]
