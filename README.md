# RadioLinks

Небольшое приложение для фонового воспроизведения прямых интернет-радиопотоков на macOS.

Исходный код находится в `RadioLinks/`. В разделе [Releases](https://github.com/frozi2-frozi2/RadioLinks/releases) опубликованы готовое приложение и полный архив исходников с ресурсами.

[Скачать готовое приложение для macOS](https://github.com/frozi2-frozi2/RadioLinks/releases/latest/download/RadioLinks-macOS.zip)

## Запуск

Скопируйте `RadioLinks.app` в папку «Программы» или на рабочий стол и откройте его. На другом Mac можно перенести весь пакет `RadioLinks.app`.

## Сборка из исходников

Для полной сборки скачайте из Releases архив `RadioLinks-source.zip`, распакуйте его и на Mac с установленными Xcode Command Line Tools выполните:

```sh
cd RadioLinks
bash build.sh
```

Скрипт собирает приложение на уровень выше папки проекта как `RadioLinks.app`.

Поддерживаются прямые HTTP/HTTPS URL радиопотоков, а также PLS/M3U плейлисты. Данные о станции и композиции отображаются, если их передаёт поток или API станции.
